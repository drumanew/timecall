-module(timecall).
-behaviour(gen_server).

-include ("timecall.hrl").

%% API.
-export([start_link/0,
         apply_after/2,
         apply_after/3,
         apply_at/2,
         cancel/1]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, { workers }).

%% API.

-spec start_link () -> {ok, pid()}.
start_link () ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec
apply_after (TimeOffset :: non_neg_integer(),
             MFA :: callspec()) -> ok | {error, badarg}.
apply_after (TimeOffset, MFA) ->
  apply_after(TimeOffset, erlang:localtime(), MFA).

-spec
apply_after (TimeOffset :: non_neg_integer(),
             Start :: calendar:datetime(),
             MFA :: callspec()) -> ok | {error, badarg}.
apply_after (TimeOffset, Start, MFA = {Mod, Fun, Args}) ->
  case is_integer(TimeOffset) andalso
       TimeOffset >= 0 andalso
       is_valid_datetime(Start) andalso
       is_atom(Mod) andalso
       is_atom(Fun) andalso
       is_list(Args) of
    true ->
      gen_server:call(?MODULE, {apply, {{Start, TimeOffset}, MFA}});
    _    -> {error, badarg}
  end;
apply_after (_, _, _) -> {error, badarg}.

-spec
apply_at (Start :: calendar:datetime(),
          MFA :: callspec()) -> ok | {error, badarg}.
apply_at (Start, MFA) ->
  apply_after(0, Start, MFA).

-spec
cancel (IdOrIds :: ref() | [ref()]) -> ok | {error, badarg}.
cancel (Ids) when is_list(Ids) ->
  case lists:all(fun is_reference/1, Ids) of
    true -> gen_server:cast(?MODULE, {cancel, Ids});
    _    -> {error, badarg}
  end;
cancel (Id) when is_reference(Id) ->
  gen_server:cast(?MODULE, {cancel, Id});
cancel (_) -> {error, badarg}.

%% gen_server.

init([]) ->
  _ = ets:new(?TAB, [named_table, {keypos, 2}, set, public]),
  Pids = start_workers(),
  {ok, #state{ workers = Pids }}.

handle_call({apply, Request}, From, State) ->
  {ok, NewState} = route_apply(Request, From, State),
  {noreply, NewState};
handle_call(_Request, _From, State) ->
  {reply, ignored, State}.

handle_cast({cancel, IdOrIds}, State) ->
  {ok, NewState} = broadcast_cancel(IdOrIds, State),
  {noreply, NewState};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% private

is_valid_datetime ({{Y,M,D}, {HH,MM,SS}})
  when is_integer(HH) andalso is_integer(MM) andalso is_integer(SS) ->
  calendar:valid_date(Y,M,D);
is_valid_datetime (_) ->
  false.

route_apply (Request, From, State = #state{ workers = [H | T]}) ->
  gen_server:cast(H, {apply, Request, From}),
  {ok, State#state{ workers = T ++ [H] }}.

broadcast_cancel (IdOrIds, State = #state{ workers = Workers }) ->
  lists:foreach(fun (Pid) -> gen_server:cast(Pid, {cancel, IdOrIds}) end,
                Workers),
  {ok, State}.

start_workers () ->
  start_workers(?WORKERS).

start_workers (N) ->
  start_workers(N, []).

start_workers (0, Acc) ->
  Acc;
start_workers (N, Acc) ->
  {ok, Pid} = timecall_server_sup:start_child(),
  start_workers(N - 1, [Pid | Acc]).

% tests
-ifdef (TEST).
-include_lib("eunit/include/eunit.hrl").

timecall_test_ () ->
  Tests = [
           basic_tests(),
           simple_tests(5, 1000),
           simple_tests_2(erlang:localtime(), 1),
           ordering_test(10),
           simple_cancel_tests(),
           multi_cancel_tests(1000)
          ],
  {"Tests for main API module",
   {setup,
    fun () -> application:start(timecall) end,
    fun (_) -> ok end,
    {inorder, Tests}}}.

basic_tests () ->
  ValidTimeOffset = 0, %1000*60*60*24*365,
  InvalidTimeOffset = -1,
  ValidDateTime = {{2018,12,12},{12,12,12}},
  InvalidDateTime = not_a_datetime,
  ValidFunSpec = {erlang, spawn, [fun () -> ok end]},
  InvalidFunSpec = not_a_function_spec,
  Tests =
    [?_assertMatch(X when is_reference(X), apply_after(ValidTimeOffset,ValidFunSpec)),
     ?_assert(apply_after(InvalidTimeOffset,ValidFunSpec) =:= {error,badarg}),
     ?_assert(apply_after(ValidTimeOffset,InvalidFunSpec) =:= {error,badarg}),
     ?_assertMatch(X when is_reference(X), apply_after(ValidTimeOffset,ValidDateTime,ValidFunSpec)),
     ?_assert(apply_after(InvalidTimeOffset,ValidDateTime,ValidFunSpec) =:= {error,badarg}),
     ?_assert(apply_after(ValidTimeOffset,InvalidDateTime,ValidFunSpec) =:= {error,badarg}),
     ?_assert(apply_after(ValidTimeOffset,ValidDateTime,InvalidFunSpec) =:= {error,badarg}),
     ?_assertMatch(X when is_reference(X), apply_at(ValidDateTime,ValidFunSpec)),
     ?_assert(apply_at(InvalidDateTime,ValidFunSpec) =:= {error,badarg}),
     ?_assert(apply_at(ValidDateTime,InvalidFunSpec) =:= {error,badarg}),
     ?_assert(cancel(make_ref()) =:= ok),
     ?_assert(cancel([make_ref(),make_ref(),make_ref()]) =:= ok),
     ?_assert(cancel(not_a_ref) =:= {error,badarg}),
     ?_assert(cancel([not_a_ref1,not_a_ref2,not_a_ref3]) =:= {error,badarg})],
  {"Basic tests: checks API functions on valid/invalid arguments", {inparallel, Tests}}.

simple_tests (Count, MaxDelay) ->
  Tests =
    lists:map(fun (_) -> simple_tests(MaxDelay) end, lists:seq(1, Count)),
  {inparallel, Tests}.

simple_tests (MaxDelay) ->
  Msg = make_ref(),
  Delay = rand:uniform(MaxDelay),
  Tests =
    [start_timer_test(Delay, Msg),
     receive_test(Delay, Msg)],
  Description =
    lists:flatten(io_lib:format("Create timer that sends message after ~p ms "
                                "and receive it", [Delay])),
  {Description, {inorder, Tests}}.

start_timer_test (Delay, Msg) ->
  FunSpec = fun () ->
              Self = self(),
              {erlang,spawn,[fun () -> Self ! Msg end]}
            end,
  {"Start timer",
   ?_assertMatch(X when is_reference(X), apply_after(Delay, FunSpec()))}.

receive_test (Delay, Msg) ->
  TimeoutSec = (Delay div 1000) + 2,
  Description =
    lists:flatten(io_lib:format("Waiting ~p sec for a message", [TimeoutSec])),
  {Description,
   {timeout,
    TimeoutSec,
    ?_assert(receive_one(Delay + 1000) =:= {ok, Msg})}}.

receive_one (Time) ->
  receive
    Msg -> {ok, Msg}
  after
    Time -> {error, timeout}
  end.

receive_all (Time) ->
  receive_all(Time, []).

receive_all (Time, Acc) ->
  receive
    Msg -> receive_all(Time, [Msg | Acc])
  after
    Time -> lists:reverse(Acc)
  end.

shuffle (List) ->
  shuffle(List, []).

shuffle ([], Acc) ->
  Acc;
shuffle (List, Acc) ->
  El = lists:nth(rand:uniform(length(List)), List),
  shuffle(List -- [El], [El | Acc]).

ordering_test (N) ->
  Timeout = N + 3,
  TestDescription =
    lists:flatten(io_lib:format(
      "Tests order of timers. This will take at most ~p sec", [Timeout])),
  CreateDescription =
    fun (X) ->
      lists:flatten(io_lib:format("Start timer: ~p sec", [X]))
    end,
  FunSpec = fun (X) ->
              Self = self(),
              {erlang, spawn, [fun () -> Self ! X end]}
            end,
  Seq = lists:seq(1, N),
  Tests =
    [ {CreateDescription(X),
       ?_assertMatch(Ref when is_reference(Ref),
                     apply_after(X*1000, FunSpec(X)))} || X <- shuffle(Seq) ] ++
    [ {"Receive messages",
       {timeout, Timeout, ?_assert(receive_all(2000) =:= Seq)}} ],
  {TestDescription, {inorder, Tests}}.

simple_cancel () ->
  Msg = make_ref(),
  FunSpec = fun () ->
              Self = self(),
              {erlang,spawn,[fun () -> Self ! Msg end]}
            end,
  Ref = apply_after(3000, FunSpec()),
  ?assertMatch(X when is_reference(X), Ref),
  ?assert(receive_one(2000) =:= {error, timeout}),
  ?assert(cancel(Ref) =:= ok),
  Recv = receive_one(2000),
  ?assert(Recv =:= {error, timeout}),
  ok.

simple_cancel_tests () ->
  {"Starts and cancels timer", [?_test(simple_cancel())]}.

multi_cancel (N) ->
  Seq = lists:seq(1, N),
  FunSpec = fun (Msg) ->
              Self = self(),
              {erlang,spawn,[fun () -> Self ! Msg end]}
            end,
  TimerMsgList =
    [ begin
        Msg = make_ref(),
        Ref = apply_after(3000, FunSpec(Msg)),
        ?assertMatch(X when is_reference(X), Ref),
        {Ref, Msg}
      end || _ <- Seq ],
  ?assert(receive_one(2000) =:= {error, timeout}),
  {Part1, Part2} = lists:split(N div 2, shuffle(TimerMsgList)),
  CancelRefs = lists:map(fun ({TimerRef, _}) -> TimerRef end, Part1),
  Expected = lists:map(fun ({_, Msg}) -> Msg end, Part2),
  ?assert(cancel(CancelRefs) =:= ok),
  Recv = receive_all(2000),
  ?assert(Recv -- Expected =:= []),
  ?assert(Expected -- Recv =:= []),
  ok.

multi_cancel_tests (N) ->
  Description = lists:flatten(io_lib:format(
    "Starts ~p timers and cancel random half of them", [N])),
  {Description, [{timeout, 60, ?_test(multi_cancel(N))}]}.

simple_tests_2 (DateTime, MinutesOffset) ->
  Msg = make_ref(),
  ApplyDateTime = date_time_next_minute(DateTime, MinutesOffset),
  ApplyDateTimeFun = fun () -> ApplyDateTime end,
  Tests =
    [start_timer_test_2(ApplyDateTime, Msg),
     receive_test(MinutesOffset*60000 + 1000, Msg),
     check_date_time(ApplyDateTimeFun, fun erlang:localtime/0)],
  Description =
    lists:flatten(io_lib:format(
      "Create timer that sends message at ~p and receive it", [ApplyDateTime])),
  {Description, {inorder, Tests}}.

start_timer_test_2 (DateTime, Msg) ->
  FunSpec = fun () ->
              Self = self(),
              {erlang,spawn,[fun () -> Self ! Msg end]}
            end,
  {"Start timer",
   ?_assertMatch(X when is_reference(X), apply_at(DateTime, FunSpec()))}.

check_date_time (Fun1, Fun2) ->
  {"Check DateTime",
   [?_test(begin
             A = Fun1(),
             B = Fun2(),
             ?assert(is_valid_datetime(A)),
             ?assert(is_valid_datetime(B)),
             ?assert(A =:= B)
           end)]}.

date_time_next_minute (DateTime) ->
  date_time_next_minute(DateTime, 1).

date_time_next_minute (DateTime, N) ->
  DateTimeSec = calendar:datetime_to_gregorian_seconds(DateTime),
  DateTimeMin = DateTimeSec div 60,
  NextMin = DateTimeMin + N,
  calendar:gregorian_seconds_to_datetime(NextMin*60).

-endif. % TEST


