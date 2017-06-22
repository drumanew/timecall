-type ref() :: reference().
-type callspec() :: {module(), atom(), [term()]}.

-define (TAB, timecall_db).
-define (WORKERS, 10).

% -define (VERBOSE, true).

-ifdef (VERBOSE).
-define (LOG(Fmt, Args), io:format(standard_error,
                                   "~n~s:~b:~p: " ++ Fmt ++ "~n",
                                   [?MODULE, ?LINE, self() | Args])).
-else.
-define (LOG(Fmt, Args), (fun (_, _) -> ok end)(Fmt, Args)).
-endif.
