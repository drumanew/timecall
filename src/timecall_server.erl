-module(timecall_server).
-behaviour(gen_server).

-include ("timecall.hrl").

%% API.
-export([start_link/0]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record (state, { table = gb_trees:empty(), timer :: ref() | undefined }).

-record (item, { id :: ref(),
                 delay :: non_neg_integer(),
                 mfa :: callspec(),
                 server :: pid() }).

-define (TIME_BASE,  16#ffffffff).

%% API.

-spec start_link () -> {ok, pid()}.
start_link () ->
  gen_server:start_link(?MODULE, [], []).

%% gen_server.

init([]) ->
  {ok, #state{}}.

handle_call(_Request, _From, State) ->
  {reply, ignored, State}.

handle_cast(_Msg = {apply, {TimeSpec, MFA}, From}, State) ->
  {Reply, NewState} = do_apply(TimeSpec, MFA, State),
  gen_server:reply(From, Reply),
  {noreply, NewState};
handle_cast({cancel, IdOrIds}, State) ->
  {ok, NewState} = do_cancel(IdOrIds, State),
  {noreply, NewState};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info = {timeout, TimerRef, {timeout, Key}},
            State = #state{ timer = TimerRef }) ->
  {ok, NewState} = do_handle_timeout(Key, State),
  {noreply, NewState};
handle_info({_Info = timeout, TimerRef, {keep, Key, Delay}},
            State = #state{ timer = TimerRef }) ->
  TimerRef = start_long_timer(Key, Delay),
  {noreply, State#state{ timer = TimerRef }};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% private

do_apply ({DateTime, Offset}, MFA, State = #state{ table = T,
                                                   timer = TimerRef }) ->
  TotalMsec = calc_total_msec(DateTime, Offset),
  Item = new_item(TotalMsec, MFA),
  NewT = add_tree(TotalMsec, Item, T),
  NewTimerRef = reshedule_tree(TimerRef, NewT),
  ets:insert(?TAB, Item),
  ?LOG("add item: ~p to shedule", [Item]),
  {Item#item.id, State#state{ table = NewT, timer = NewTimerRef }}.

do_handle_timeout (TotalDelay, State = #state{ table = T, timer = TimerRef }) ->
  NewT =
    case catch gb_trees:take_smallest(T) of
      {TotalDelay, Items, T0} ->
        ok = gb_sets:fold(fun (X, Acc) -> item_fired(X), Acc end, ok, Items),
        T0;
      _ -> T
    end,
  NewTimerRef = reshedule_tree(TimerRef, NewT),
  {ok, State#state{ table = NewT, timer = NewTimerRef }}.

calc_total_msec (DateTime, Offset) ->
  Start = calendar:datetime_to_gregorian_seconds(DateTime),
  Start*1000 + Offset.

calc_total_delay (TotalMsec) ->
  Now = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
  NowMsec = Now*1000,
  TotalDelay = TotalMsec - NowMsec,
  case TotalDelay < 0 of
    true ->
      ?LOG("event in past: we are not time machine: BUG!", []),
      0;
    _ -> TotalDelay
  end.

new_item (TotalDelay, MFA) ->
  #item{ id = make_ref(), delay = TotalDelay, mfa = MFA, server = self() }.

add_tree (Key, Item, Tree) ->
  case gb_trees:lookup(Key, Tree) of
    none -> gb_trees:insert(Key, gb_sets:singleton(Item), Tree);
    {value, OldV} ->
      NewV = gb_sets:add(Item, OldV),
      gb_trees:update(Key, NewV, Tree)
  end.

del_tree (Key, Item, Tree) ->
  case gb_trees:lookup(Key, Tree) of
    none -> Tree;
    {value, OldV} ->
      NewV = gb_sets:delete_any(Item, OldV),
      case gb_sets:size(NewV) of
        0 -> gb_trees:delete_any(Key, Tree);
        _ -> gb_trees:update(Key, NewV, Tree)
      end
  end.

reshedule_tree (TimerRef, Tree) ->
  cancel_timer(TimerRef),
  case catch gb_trees:smallest(Tree) of
    {'EXIT', _} -> undefined;
    {TotalMsec, _} ->
      TotalDelay = calc_total_delay(TotalMsec),
      start_long_timer(TotalMsec, TotalDelay)
  end.

cancel_timer (T) when is_reference(T) ->
  _ = erlang:cancel_timer(T),
  ok;
cancel_timer (_) ->
  ok.

start_long_timer (Msg, TotalDelay) ->
  case ?TIME_BASE < TotalDelay of
    true ->
      erlang:start_timer(?TIME_BASE, self(), {keep, Msg, TotalDelay - ?TIME_BASE});
    _ ->
      erlang:start_timer(TotalDelay, self(), {timeout, Msg})
  end.

item_fired (_Item = #item{ id = Id, mfa = {M,F,A} }) ->
  ?LOG("call item: ~p", [_Item]),
  spawn(fun () ->
          catch apply(M, F, A)
        end),
  ets:delete(?TAB, Id),
  ok.

do_cancel (Id, State = #state{ table = T, timer = TimerRef })
  when is_reference(Id) ->
  Self = self(),
  case ets:lookup(?TAB, Id) of
    [Item = #item{ delay = Key, server = Self }] ->
      NewT = del_tree(Key, Item, T),
      NewTimerRef = reshedule_tree(TimerRef, NewT),
      ets:delete(?TAB, Id),
      ?LOG("remove item: ~p from shedule", [Item]),
      {ok, State#state{ table = NewT, timer = NewTimerRef }};
    _ -> {ok, State}
  end;
do_cancel (Ids, State) when is_list(Ids) ->
  {ok,
   lists:foldl(fun (Id, Acc) ->
                 {ok, NewAcc} = do_cancel(Id, Acc),
                 NewAcc
               end, State, Ids)};
do_cancel (_, State) ->
  {ok, State}.
