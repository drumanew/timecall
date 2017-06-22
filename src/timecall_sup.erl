-module(timecall_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
  Procs = [{timecall_server_sup,
            {timecall_server_sup, start_link, []},
            permanent,
            infinity,
            supervisor,
            [timecall_server_sup]},
           {timecall,
            {timecall, start_link, []},
            permanent,
            2000,
            worker,
            [timecall]}],
  {ok, {{one_for_one, 1, 5}, Procs}}.
