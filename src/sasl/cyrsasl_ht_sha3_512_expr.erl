-module(cyrsasl_ht_sha3_512_expr).
-behaviour(cyrsasl).

-export([mechanism/0, mech_new/3, mech_step/2]).
-ignore_xref([mech_new/3]).

-spec mechanism() -> cyrsasl:mechanism().
mechanism() ->
    <<"HT-SHA-3-512-EXPR">>.

-spec mech_new(Host   :: jid:server(),
               Creds  :: mongoose_credentials:t(),
               SocketData :: term()) -> {ok, tuple()} | {error, binary()}.
mech_new(Host, Creds, SocketData) ->
    mod_fast_auth_token_generic_mech:mech_new(Host, Creds, SocketData, mechanism()).

-spec mech_step(State :: tuple(),
                ClientIn :: binary()) -> {ok, mongoose_credentials:t()}
                                       | {error, binary()}.
mech_step(State, SerializedToken) ->
    mod_fast_auth_token_generic_mech:mech_step(State, SerializedToken).
