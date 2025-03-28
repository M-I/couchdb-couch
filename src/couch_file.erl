% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_file).
-behaviour(gen_server).
-vsn(1).

-include_lib("couch/include/couch_db.hrl").


-define(INITIAL_WAIT, 60000).
-define(MONITOR_CHECK, 10000).
-define(SIZE_BLOCK, 16#1000). % 4 KiB


-record(file, {
    fd,
    is_sys,
    eof = 0,
    db_pid
}).

% public API
-export([open/1, open/2, close/1, bytes/1, sync/1, truncate/2, set_db_pid/2]).
-export([pread_term/2, pread_iolist/2, pread_binary/2]).
-export([append_binary/2, append_binary_md5/2]).
-export([append_raw_chunk/2, assemble_file_chunk/1, assemble_file_chunk/2]).
-export([append_term/2, append_term/3, append_term_md5/2, append_term_md5/3]).
-export([write_header/2, read_header/1]).
-export([delete/2, delete/3, nuke_dir/2, init_delete_dir/1]).

% gen_server callbacks
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

%% helper functions
-export([process_info/1]).

%%----------------------------------------------------------------------
%% Args:   Valid Options are [create] and [create,overwrite].
%%  Files are opened in read/write mode.
%% Returns: On success, {ok, Fd}
%%  or {error, Reason} if the file could not be opened.
%%----------------------------------------------------------------------

open(Filepath) ->
    open(Filepath, []).

open(Filepath, Options) ->
    case gen_server:start_link(couch_file,
            {Filepath, Options, self(), Ref = make_ref()}, []) of
    {ok, Fd} ->
        {ok, Fd};
    ignore ->
        % get the error
        receive
        {Ref, Pid, {error, Reason} = Error} ->
            case process_info(self(), trap_exit) of
            {trap_exit, true} -> receive {'EXIT', Pid, _} -> ok end;
            {trap_exit, false} -> ok
            end,
            case {lists:member(nologifmissing, Options), Reason} of
            {true, enoent} -> ok;
            _ ->
            couch_log:error("Could not open file ~s: ~s",
                            [Filepath, file:format_error(Reason)])
            end,
            Error
        end;
    Error ->
        % We can't say much here, because it could be any kind of error.
        % Just let it bubble and an encapsulating subcomponent can perhaps
        % be more informative. It will likely appear in the SASL log, anyway.
        Error
    end.


set_db_pid(Fd, Pid) ->
    gen_server:call(Fd, {set_db_pid, Pid}).


%%----------------------------------------------------------------------
%% Purpose: To append an Erlang term to the end of the file.
%% Args:    Erlang term to serialize and append to the file.
%% Returns: {ok, Pos, NumBytesWritten} where Pos is the file offset to
%%  the beginning the serialized  term. Use pread_term to read the term
%%  back.
%%  or {error, Reason}.
%%----------------------------------------------------------------------

append_term(Fd, Term) ->
    append_term(Fd, Term, []).

append_term(Fd, Term, Options) ->
    Comp = couch_util:get_value(compression, Options, ?DEFAULT_COMPRESSION),
    append_binary(Fd, couch_compress:compress(Term, Comp)).

append_term_md5(Fd, Term) ->
    append_term_md5(Fd, Term, []).

append_term_md5(Fd, Term, Options) ->
    Comp = couch_util:get_value(compression, Options, ?DEFAULT_COMPRESSION),
    append_binary_md5(Fd, couch_compress:compress(Term, Comp)).

%%----------------------------------------------------------------------
%% Purpose: To append an Erlang binary to the end of the file.
%% Args:    Erlang term to serialize and append to the file.
%% Returns: {ok, Pos, NumBytesWritten} where Pos is the file offset to the
%%  beginning the serialized term. Use pread_term to read the term back.
%%  or {error, Reason}.
%%----------------------------------------------------------------------

append_binary(Fd, Bin) ->
    ioq:call(Fd, {append_bin, assemble_file_chunk(Bin)}, erlang:get(io_priority)).
    
append_binary_md5(Fd, Bin) ->
    ioq:call(Fd,
        {append_bin, assemble_file_chunk(Bin, couch_crypto:hash(md5, Bin))},
        erlang:get(io_priority)).

append_raw_chunk(Fd, Chunk) ->
    ioq:call(Fd, {append_bin, Chunk}, erlang:get(io_priority)).


assemble_file_chunk(Bin) ->
    [<<0:1/integer, (iolist_size(Bin)):31/integer>>, Bin].

assemble_file_chunk(Bin, Md5) ->
    [<<1:1/integer, (iolist_size(Bin)):31/integer>>, Md5, Bin].

%%----------------------------------------------------------------------
%% Purpose: Reads a term from a file that was written with append_term
%% Args:    Pos, the offset into the file where the term is serialized.
%% Returns: {ok, Term}
%%  or {error, Reason}.
%%----------------------------------------------------------------------


pread_term(Fd, Pos) ->
    {ok, Bin} = pread_binary(Fd, Pos),
    {ok, couch_compress:decompress(Bin)}.


%%----------------------------------------------------------------------
%% Purpose: Reads a binrary from a file that was written with append_binary
%% Args:    Pos, the offset into the file where the term is serialized.
%% Returns: {ok, Term}
%%  or {error, Reason}.
%%----------------------------------------------------------------------

pread_binary(Fd, Pos) ->
    {ok, L} = pread_iolist(Fd, Pos),
    {ok, iolist_to_binary(L)}.


pread_iolist(Fd, Pos) ->
    case ioq:call(Fd, {pread_iolist, Pos}, erlang:get(io_priority)) of
    {ok, IoList, <<>>} ->
        {ok, IoList};
    {ok, IoList, Md5} ->
        case couch_crypto:hash(md5, IoList) of
        Md5 ->
            {ok, IoList};
        _ ->
            couch_log:emergency("File corruption in ~p at position ~B",
                     [Fd, Pos]),
            exit({file_corruption, <<"file corruption">>})
        end;
    Error ->
        Error
    end.

%%----------------------------------------------------------------------
%% Purpose: The length of a file, in bytes.
%% Returns: {ok, Bytes}
%%  or {error, Reason}.
%%----------------------------------------------------------------------

% length in bytes
bytes(Fd) ->
    gen_server:call(Fd, bytes, infinity).

%%----------------------------------------------------------------------
%% Purpose: Truncate a file to the number of bytes.
%% Returns: ok
%%  or {error, Reason}.
%%----------------------------------------------------------------------

truncate(Fd, Pos) ->
    gen_server:call(Fd, {truncate, Pos}, infinity).

%%----------------------------------------------------------------------
%% Purpose: Ensure all bytes written to the file are flushed to disk.
%% Returns: ok
%%  or {error, Reason}.
%%----------------------------------------------------------------------

sync(Filepath) when is_list(Filepath) ->
    {ok, Fd} = file:open(Filepath, [append, raw]),
    try ok = file:sync(Fd) after ok = file:close(Fd) end;
sync(Fd) ->
    gen_server:call(Fd, sync, infinity).

%%----------------------------------------------------------------------
%% Purpose: Close the file.
%% Returns: ok
%%----------------------------------------------------------------------
close(Fd) ->
    gen_server:call(Fd, close, infinity).


delete(RootDir, Filepath) ->
    delete(RootDir, Filepath, []).

delete(RootDir, FullFilePath, Options) ->
    EnableRecovery = config:get_boolean("couchdb",
        "enable_database_recovery", false),
    Async = not lists:member(sync, Options),
    Context = couch_util:get_value(context, Options, compaction),
    case Context =:= delete andalso EnableRecovery of
        true ->
            rename_file(FullFilePath);
        false ->
            DeleteAfterRename = config:get_boolean("couchdb",
                "delete_after_rename", true),
            delete_file(RootDir, FullFilePath, Async, DeleteAfterRename)
    end.

delete_file(RootDir, Filepath, Async, DeleteAfterRename) ->
    DelFile = filename:join([RootDir,".delete", ?b2l(couch_uuids:random())]),
    case file:rename(Filepath, DelFile) of
    ok when DeleteAfterRename ->
        if (Async) ->
            spawn(file, delete, [DelFile]),
            ok;
        true ->
            file:delete(DelFile)
        end;
    Else ->
        Else
    end.

rename_file(Original) ->
    DeletedFileName = deleted_filename(Original),
    Now = calendar:local_time(),
    case file:rename(Original, DeletedFileName) of
        ok -> file:change_time(DeletedFileName, Now);
        Else -> Else
    end.

deleted_filename(Original) ->
    {{Y, Mon, D}, {H, Min, S}} = calendar:universal_time(),
    Suffix = lists:flatten(
        io_lib:format(".~w~2.10.0B~2.10.0B."
            ++ "~2.10.0B~2.10.0B~2.10.0B.deleted"
            ++ filename:extension(Original), [Y, Mon, D, H, Min, S])),
    filename:rootname(Original) ++ Suffix.

nuke_dir(RootDelDir, Dir) ->
    EnableRecovery = config:get_boolean("couchdb",
        "enable_database_recovery", false),
    case EnableRecovery of
        true ->
            rename_file(Dir);
        false ->
            delete_dir(RootDelDir, Dir)
    end.

delete_dir(RootDelDir, Dir) ->
    DeleteAfterRename = config:get_boolean("couchdb",
        "delete_after_rename", true),
    FoldFun = fun(File) ->
        Path = Dir ++ "/" ++ File,
        case filelib:is_dir(Path) of
            true ->
                ok = nuke_dir(RootDelDir, Path),
                file:del_dir(Path);
            false ->
                delete_file(RootDelDir, Path, false, DeleteAfterRename)
        end
    end,
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(FoldFun, Files),
            ok = file:del_dir(Dir);
        {error, enoent} ->
            ok
    end.


init_delete_dir(RootDir) ->
    Dir = filename:join(RootDir,".delete"),
    % note: ensure_dir requires an actual filename companent, which is the
    % reason for "foo".
    filelib:ensure_dir(filename:join(Dir,"foo")),
    spawn(fun() ->
        filelib:fold_files(Dir, ".*", true,
            fun(Filename, _) ->
                ok = file:delete(Filename)
            end, ok)
    end),
    ok.


read_header(Fd) ->
    case ioq:call(Fd, find_header, erlang:get(io_priority)) of
    {ok, Bin} ->
        {ok, binary_to_term(Bin)};
    Else ->
        Else
    end.

write_header(Fd, Data) ->
    Bin = term_to_binary(Data),
    Md5 = couch_crypto:hash(md5, Bin),
    % now we assemble the final header binary and write to disk
    FinalBin = <<Md5/binary, Bin/binary>>,
    ioq:call(Fd, {write_header, FinalBin}, erlang:get(io_priority)).


init_status_error(ReturnPid, Ref, Error) ->
    ReturnPid ! {Ref, self(), Error},
    ignore.

% server functions

init({Filepath, Options, ReturnPid, Ref}) ->
    process_flag(trap_exit, true),
    OpenOptions = file_open_options(Options),
    case lists:member(create, Options) of
    true ->
        filelib:ensure_dir(Filepath),
        case file:open(Filepath, OpenOptions) of
        {ok, Fd} ->
            %% Save Fd in process dictionary for debugging purposes
            put(couch_file_fd, {Fd, Filepath}),
            {ok, Length} = file:position(Fd, eof),
            case Length > 0 of
            true ->
                % this means the file already exists and has data.
                % FYI: We don't differentiate between empty files and non-existant
                % files here.
                case lists:member(overwrite, Options) of
                true ->
                    {ok, 0} = file:position(Fd, 0),
                    ok = file:truncate(Fd),
                    ok = file:sync(Fd),
                    maybe_track_open_os_files(Options),
                    erlang:send_after(?INITIAL_WAIT, self(), maybe_close),
                    {ok, #file{fd=Fd, is_sys=lists:member(sys_db, Options)}};
                false ->
                    ok = file:close(Fd),
                    init_status_error(ReturnPid, Ref, {error, eexist})
                end;
            false ->
                maybe_track_open_os_files(Options),
                erlang:send_after(?INITIAL_WAIT, self(), maybe_close),
                {ok, #file{fd=Fd, is_sys=lists:member(sys_db, Options)}}
            end;
        Error ->
            init_status_error(ReturnPid, Ref, Error)
        end;
    false ->
        % open in read mode first, so we don't create the file if it doesn't exist.
        case file:open(Filepath, [read, raw]) of
        {ok, Fd_Read} ->
            {ok, Fd} = file:open(Filepath, OpenOptions),
            %% Save Fd in process dictionary for debugging purposes
            put(couch_file_fd, {Fd, Filepath}),
            ok = file:close(Fd_Read),
            maybe_track_open_os_files(Options),
            {ok, Eof} = file:position(Fd, eof),
            erlang:send_after(?INITIAL_WAIT, self(), maybe_close),
            {ok, #file{fd=Fd, eof=Eof, is_sys=lists:member(sys_db, Options)}};
        Error ->
            init_status_error(ReturnPid, Ref, Error)
        end
    end.

file_open_options(Options) ->
    [read, raw, binary] ++ case lists:member(read_only, Options) of
    true ->
        [];
    false ->
        [append]
    end.

maybe_track_open_os_files(Options) ->
    case not lists:member(sys_db, Options) of
        true ->
            couch_stats_process_tracker:track([couchdb, open_os_files]);
        false ->
            ok
    end.

terminate(_Reason, #file{fd = nil}) ->
    ok;
terminate(_Reason, #file{fd = Fd}) ->
    ok = file:close(Fd).

handle_call(close, _From, #file{fd=Fd}=File) ->
    {stop, normal, file:close(Fd), File#file{fd = nil}};

handle_call({pread_iolist, Pos}, _From, File) ->
    {RawData, NextPos} = try
        % up to 8Kbs of read ahead
        read_raw_iolist_int(File, Pos, 2 * ?SIZE_BLOCK - (Pos rem ?SIZE_BLOCK))
    catch
    _:_ ->
        read_raw_iolist_int(File, Pos, 4)
    end,
    <<Prefix:1/integer, Len:31/integer, RestRawData/binary>> =
        iolist_to_binary(RawData),
    case Prefix of
    1 ->
        {Md5, IoList} = extract_md5(
            maybe_read_more_iolist(RestRawData, 16 + Len, NextPos, File)),
        {reply, {ok, IoList, Md5}, File};
    0 ->
        IoList = maybe_read_more_iolist(RestRawData, Len, NextPos, File),
        {reply, {ok, IoList, <<>>}, File}
    end;

handle_call(bytes, _From, #file{fd = Fd} = File) ->
    {reply, file:position(Fd, eof), File};

handle_call({set_db_pid, Pid}, _From, #file{db_pid=OldPid}=File) ->
    case is_pid(OldPid) of
        true -> unlink(OldPid);
        false -> ok
    end,
    link(Pid),
    {reply, ok, File#file{db_pid=Pid}};

handle_call(sync, _From, #file{fd=Fd}=File) ->
    {reply, file:sync(Fd), File};

handle_call({truncate, Pos}, _From, #file{fd=Fd}=File) ->
    {ok, Pos} = file:position(Fd, Pos),
    case file:truncate(Fd) of
    ok ->
        {reply, ok, File#file{eof = Pos}};
    Error ->
        {reply, Error, File}
    end;

handle_call({append_bin, Bin}, _From, #file{fd = Fd, eof = Pos} = File) ->
    Blocks = make_blocks(Pos rem ?SIZE_BLOCK, Bin),
    Size = iolist_size(Blocks),
    case file:write(Fd, Blocks) of
    ok ->
        {reply, {ok, Pos, Size}, File#file{eof = Pos + Size}};
    Error ->
        {reply, Error, File}
    end;

handle_call({write_header, Bin}, _From, #file{fd = Fd, eof = Pos} = File) ->
    BinSize = byte_size(Bin),
    case Pos rem ?SIZE_BLOCK of
    0 ->
        Padding = <<>>;
    BlockOffset ->
        Padding = <<0:(8*(?SIZE_BLOCK-BlockOffset))>>
    end,
    FinalBin = [Padding, <<1, BinSize:32/integer>> | make_blocks(5, [Bin])],
    case file:write(Fd, FinalBin) of
    ok ->
        {reply, ok, File#file{eof = Pos + iolist_size(FinalBin)}};
    Error ->
        {reply, Error, File}
    end;

handle_call(find_header, _From, #file{fd = Fd, eof = Pos} = File) ->
    {reply, find_header(Fd, Pos div ?SIZE_BLOCK), File}.

handle_cast(close, Fd) ->
    {stop,normal,Fd}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_info(maybe_close, File) ->
    case is_idle(File) of
        true ->
            {stop, normal, File};
        false ->
            erlang:send_after(?MONITOR_CHECK, self(), maybe_close),
            {noreply, File}
    end;

handle_info({'EXIT', Pid, _}, #file{db_pid=Pid}=File) ->
    case is_idle(File) of
        true -> {stop, normal, File};
        false -> {noreply, File}
    end;

handle_info({'EXIT', _, normal}, Fd) ->
    {noreply, Fd};
handle_info({'EXIT', _, Reason}, Fd) ->
    {stop, Reason, Fd}.


find_header(_Fd, -1) ->
    no_valid_header;
find_header(Fd, Block) ->
    case (catch load_header(Fd, Block)) of
    {ok, Bin} ->
        {ok, Bin};
    _Error ->
        find_header(Fd, Block -1)
    end.

load_header(Fd, Block) ->
    {ok, <<1, HeaderLen:32/integer, RestBlock/binary>>} =
        file:pread(Fd, Block * ?SIZE_BLOCK, ?SIZE_BLOCK),
    TotalBytes = calculate_total_read_len(5, HeaderLen),
    case TotalBytes > byte_size(RestBlock) of
    false ->
        <<RawBin:TotalBytes/binary, _/binary>> = RestBlock;
    true ->
        {ok, Missing} = file:pread(
            Fd, (Block * ?SIZE_BLOCK) + 5 + byte_size(RestBlock),
            TotalBytes - byte_size(RestBlock)),
        RawBin = <<RestBlock/binary, Missing/binary>>
    end,
    <<Md5Sig:16/binary, HeaderBin/binary>> =
        iolist_to_binary(remove_block_prefixes(5, RawBin)),
    Md5Sig = couch_crypto:hash(md5, HeaderBin),
    {ok, HeaderBin}.

maybe_read_more_iolist(Buffer, DataSize, _, _)
    when DataSize =< byte_size(Buffer) ->
    <<Data:DataSize/binary, _/binary>> = Buffer,
    [Data];
maybe_read_more_iolist(Buffer, DataSize, NextPos, File) ->
    {Missing, _} =
        read_raw_iolist_int(File, NextPos, DataSize - byte_size(Buffer)),
    [Buffer, Missing].

-spec read_raw_iolist_int(#file{}, Pos::non_neg_integer(), Len::non_neg_integer()) ->
    {Data::iolist(), CurPos::non_neg_integer()}.
read_raw_iolist_int(Fd, {Pos, _Size}, Len) -> % 0110 UPGRADE CODE
    read_raw_iolist_int(Fd, Pos, Len);
read_raw_iolist_int(#file{fd = Fd}, Pos, Len) ->
    BlockOffset = Pos rem ?SIZE_BLOCK,
    TotalBytes = calculate_total_read_len(BlockOffset, Len),
    {ok, <<RawBin:TotalBytes/binary>>} = file:pread(Fd, Pos, TotalBytes),
    {remove_block_prefixes(BlockOffset, RawBin), Pos + TotalBytes}.

-spec extract_md5(iolist()) -> {binary(), iolist()}.
extract_md5(FullIoList) ->
    {Md5List, IoList} = split_iolist(FullIoList, 16, []),
    {iolist_to_binary(Md5List), IoList}.

calculate_total_read_len(0, FinalLen) ->
    calculate_total_read_len(1, FinalLen) + 1;
calculate_total_read_len(BlockOffset, FinalLen) ->
    case ?SIZE_BLOCK - BlockOffset of
    BlockLeft when BlockLeft >= FinalLen ->
        FinalLen;
    BlockLeft ->
        FinalLen + ((FinalLen - BlockLeft) div (?SIZE_BLOCK -1)) +
            if ((FinalLen - BlockLeft) rem (?SIZE_BLOCK -1)) =:= 0 -> 0;
                true -> 1 end
    end.

remove_block_prefixes(_BlockOffset, <<>>) ->
    [];
remove_block_prefixes(0, <<_BlockPrefix,Rest/binary>>) ->
    remove_block_prefixes(1, Rest);
remove_block_prefixes(BlockOffset, Bin) ->
    BlockBytesAvailable = ?SIZE_BLOCK - BlockOffset,
    case size(Bin) of
    Size when Size > BlockBytesAvailable ->
        <<DataBlock:BlockBytesAvailable/binary,Rest/binary>> = Bin,
        [DataBlock | remove_block_prefixes(0, Rest)];
    _Size ->
        [Bin]
    end.

make_blocks(_BlockOffset, []) ->
    [];
make_blocks(0, IoList) ->
    [<<0>> | make_blocks(1, IoList)];
make_blocks(BlockOffset, IoList) ->
    case split_iolist(IoList, (?SIZE_BLOCK - BlockOffset), []) of
    {Begin, End} ->
        [Begin | make_blocks(0, End)];
    _SplitRemaining ->
        IoList
    end.

%% @doc Returns a tuple where the first element contains the leading SplitAt
%% bytes of the original iolist, and the 2nd element is the tail. If SplitAt
%% is larger than byte_size(IoList), return the difference.
-spec split_iolist(IoList::iolist(), SplitAt::non_neg_integer(), Acc::list()) ->
    {iolist(), iolist()} | non_neg_integer().
split_iolist(List, 0, BeginAcc) ->
    {lists:reverse(BeginAcc), List};
split_iolist([], SplitAt, _BeginAcc) ->
    SplitAt;
split_iolist([<<Bin/binary>> | Rest], SplitAt, BeginAcc) when SplitAt > byte_size(Bin) ->
    split_iolist(Rest, SplitAt - byte_size(Bin), [Bin | BeginAcc]);
split_iolist([<<Bin/binary>> | Rest], SplitAt, BeginAcc) ->
    <<Begin:SplitAt/binary,End/binary>> = Bin,
    split_iolist([End | Rest], 0, [Begin | BeginAcc]);
split_iolist([Sublist| Rest], SplitAt, BeginAcc) when is_list(Sublist) ->
    case split_iolist(Sublist, SplitAt, BeginAcc) of
    {Begin, End} ->
        {Begin, [End | Rest]};
    SplitRemaining ->
        split_iolist(Rest, SplitAt - (SplitAt - SplitRemaining), [Sublist | BeginAcc])
    end;
split_iolist([Byte | Rest], SplitAt, BeginAcc) when is_integer(Byte) ->
    split_iolist(Rest, SplitAt - 1, [Byte | BeginAcc]).


% System dbs aren't monitored by couch_stats_process_tracker
is_idle(#file{is_sys=true}) ->
    case process_info(self(), monitored_by) of
        {monitored_by, []} -> true;
        _ -> false
    end;
is_idle(#file{is_sys=false}) ->
    Tracker = whereis(couch_stats_process_tracker),
    case process_info(self(), monitored_by) of
        {monitored_by, []} -> true;
        {monitored_by, [Tracker]} -> true;
        {monitored_by, [_]} -> exit(tracker_monitoring_failed);
        _ -> false
    end.

-spec process_info(CouchFilePid :: pid()) ->
    {Fd :: pid() | tuple(), FilePath :: string()}.

process_info(Pid) ->
    {dictionary, Dict} = erlang:process_info(Pid, dictionary),
    case lists:keyfind(couch_file_fd, 1, Dict) of
        false ->
            undefined;
        {couch_file_fd, {Fd, InitialName}} ->
            {Fd, InitialName}
    end.


-ifdef(TEST).
-include_lib("couch/include/couch_eunit.hrl").

deleted_filename_test_() ->
    DbNames = ["dbname", "db.name", "user/dbname"],
    Fixtures = make_filename_fixtures(DbNames),
    lists:map(fun(Fixture) ->
        should_create_proper_deleted_filename(Fixture)
    end, Fixtures).

should_create_proper_deleted_filename(Before) ->
    {Before,
    ?_test(begin
        BeforeExtension = filename:extension(Before),
        BeforeBasename = filename:basename(Before, BeforeExtension),
        Re = "^" ++ BeforeBasename ++ "\.[0-9]{8}\.[0-9]{6}\.deleted\..*$",
        After = deleted_filename(Before),
        ?assertEqual(match,
            re:run(filename:basename(After), Re, [{capture, none}])),
        ?assertEqual(BeforeExtension, filename:extension(After))
    end)}.

make_filename_fixtures(DbNames) ->
    Formats = [
        "~s.couch",
        ".~s_design/mrview/3133e28517e89a3e11435dd5ac4ad85a.view",
        "shards/00000000-1fffffff/~s.1458336317.couch",
        ".shards/00000000-1fffffff/~s.1458336317_design",
        ".shards/00000000-1fffffff/~s.1458336317_design"
            "/mrview/3133e28517e89a3e11435dd5ac4ad85a.view"
    ],
    lists:flatmap(fun(DbName) ->
        lists:map(fun(Format) ->
            filename:join("/srv/data", io_lib:format(Format, [DbName]))
        end, Formats)
    end, DbNames).

-endif.
