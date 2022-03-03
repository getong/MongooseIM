-module(mongoose_graphql_enum).

-export([input/2, output/2]).

-ignore_xref([input/2, output/2]).

input(<<"PresenceShow">>, Show) ->
    {ok, list_to_binary(string:to_lower(binary_to_list(Show)))};
input(<<"PresenceType">>, Type) ->
    {ok, list_to_binary(string:to_lower(binary_to_list(Type)))};
input(<<"AuthStatus">>, <<"AUTHORIZED">>) -> {ok, 'AUTHORIZED'};
input(<<"AuthStatus">>, <<"UNAUTHORIZED">>)  -> {ok, 'UNAUTHORIZED'};
input(<<"Affiliation">>, <<"OWNER">>) -> {ok, owner};
input(<<"Affiliation">>, <<"MEMBER">>) -> {ok, member};
input(<<"Affiliation">>, <<"NONE">>) -> {ok, none};
input(<<"BlockingAction">>, <<"ALLOW">>) -> {ok, allow};
input(<<"BlockingAction">>, <<"DENY">>) -> {ok, deny};
input(<<"BlockedEntityType">>, <<"USER">>) -> {ok, user};
input(<<"BlockedEntityType">>, <<"ROOM">>) -> {ok, room}.

output(<<"PresenceShow">>, Show) ->
    {ok, list_to_binary(string:to_upper(binary_to_list(Show)))};
output(<<"PresenceType">>, Type) ->
    {ok, list_to_binary(string:to_upper(binary_to_list(Type)))};
output(<<"AuthStatus">>, Status) ->
    {ok, atom_to_binary(Status, utf8)};
output(<<"Affiliation">>, Aff) ->
    {ok, list_to_binary(string:to_upper(atom_to_list(Aff)))};
output(<<"BlockingAction">>, Action) ->
    {ok, list_to_binary(string:to_upper(atom_to_list(Action)))};
output(<<"BlockedEntityType">>, What) ->
    {ok, list_to_binary(string:to_upper(atom_to_list(What)))}.
