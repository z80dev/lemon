-module(copilot_check).
-export([check/0]).

check() ->
    Node = 'lemon@newphy',
    {ok, Raw, _} = rpc:call(Node, 'Elixir.LemonCore.Secrets', resolve,
        [<<"llm_github_copilot_api_key">>, [[{env_fallback, true}]]]),
    {ok, Map} = rpc:call(Node, 'Elixir.Jason', decode, [Raw]),

    Expires = maps:get(<<"expires_at_ms">>, Map),
    Now = erlang:system_time(millisecond),
    io:format("expires_at_ms: ~p~n", [Expires]),
    io:format("now_ms:         ~p~n", [Now]),
    io:format("is_expired:     ~p~n", [Now > Expires]),

    Token = maps:get(<<"access_token">>, Map),
    {match, [ExpBin]} = re:run(Token, "exp=(\\d+)", [{capture, all_but_first, binary}]),
    ExpSec = binary_to_integer(ExpBin),
    NowSec = erlang:system_time(second),
    io:format("token_exp (s):  ~p~n", [ExpSec]),
    io:format("now (s):         ~p~n", [NowSec]),
    io:format("token_expired:   ~p~n", [NowSec > ExpSec]),

    io:format("~nAttempting refresh...~n"),
    RefreshResult = rpc:call(Node, 'Elixir.Ai.Auth.GitHubCopilotOAuth', resolve_api_key_from_secret,
        [<<"llm_github_copilot_api_key">>, Raw]),
    io:format("Refresh result: ~p~n", [RefreshResult]),

    case RefreshResult of
        {ok, NewToken} ->
            io:format("New token length: ~p~n", [byte_size(NewToken)]);
        _ ->
            ok
    end,

    halt(0).
