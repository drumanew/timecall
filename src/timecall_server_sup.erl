-module(timecall_server_sup).
-behaviour(supervisor).

-export([start_link/0,
         start_child/0]).

-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_child () ->
  supervisor:start_child(?MODULE, []).

init([]) ->
  Procs = [{timecall_server,
            {timecall_server, start_link, []},
            permanent,
            2000,
            worker,
            [timecall_server]}],
  {ok, {{simple_one_for_one, 1, 5}, Procs}}.
