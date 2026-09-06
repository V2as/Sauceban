"""Message types for the StatsService RPCs that report per-user online IPs.

`xray_api/proto/` was generated from an older Xray-core release, so the
vendored `StatsService` stub only knows GetStats / QueryStats / GetSysStats.
Xray-core later added per-user online-IP reporting:

    rpc GetStatsOnlineIpList(GetStatsRequest) returns (GetStatsOnlineIpListResponse)
    rpc GetAllOnlineUsers(GetAllOnlineUsersRequest) returns (GetAllOnlineUsersResponse)
    rpc GetUsersStats(GetUsersStatsRequest) returns (GetUsersStatsResponse)

Each landed in a different release, so a core may implement any prefix of that
list: `GetStatsOnlineIpList` since v25.2.18, `GetAllOnlineUsers` since
v25.12.1, `GetUsersStats` since v26.4.13. Missing ones answer UNIMPLEMENTED,
which `stats.py` turns into `NotSupportedError`.

Regenerating the vendored tree would rewrite every generated module and tie
the panel to whatever protobuf runtime the new protoc emits for, so the few
messages these two calls need are described here instead, at import time, in a
private descriptor pool (nothing is added to the global one).

Only field numbers matter on the wire, and those mirror upstream
`app/stats/command/command.proto`. The package name below is local and never
transmitted; the method paths are what identify the RPCs to the core.

`GetStatsOnlineIpListResponse.ips` is a `map<string, int64>` upstream. A
protobuf map is encoded exactly like a repeated message of `{key, value}`
entries, so it is declared that way here and read as `entry.key` /
`entry.value`.
"""
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

try:  # protobuf >= 4.22
    from google.protobuf.message_factory import GetMessageClass as _message_class
except ImportError:  # pragma: no cover - older runtimes
    _message_class = None

_PACKAGE = "sauceban.xray_online"
_POOL = descriptor_pool.DescriptorPool()

_STATS_SERVICE = "/xray.app.stats.command.StatsService"
GET_USERS_STATS_METHOD = f"{_STATS_SERVICE}/GetUsersStats"
GET_STATS_ONLINE_IP_LIST_METHOD = f"{_STATS_SERVICE}/GetStatsOnlineIpList"
GET_ALL_ONLINE_USERS_METHOD = f"{_STATS_SERVICE}/GetAllOnlineUsers"

_TYPES = descriptor_pb2.FieldDescriptorProto
_SINGULAR = _TYPES.LABEL_OPTIONAL
_REPEATED = _TYPES.LABEL_REPEATED


def _add_field(message, name, number, type_, label=_SINGULAR, type_name=None):
    field = message.field.add()
    field.name = name
    field.number = number
    field.type = type_
    field.label = label
    if type_name:
        field.type_name = f".{_PACKAGE}.{type_name}"


def _build_file() -> descriptor_pb2.FileDescriptorProto:
    file = descriptor_pb2.FileDescriptorProto()
    file.name = "sauceban/xray_online.proto"
    file.package = _PACKAGE
    file.syntax = "proto3"

    request = file.message_type.add()
    request.name = "GetStatsRequest"
    _add_field(request, "name", 1, _TYPES.TYPE_STRING)
    _add_field(request, "reset", 2, _TYPES.TYPE_BOOL)

    entry = file.message_type.add()
    entry.name = "IpEntry"
    _add_field(entry, "key", 1, _TYPES.TYPE_STRING)
    _add_field(entry, "value", 2, _TYPES.TYPE_INT64)

    ip_list = file.message_type.add()
    ip_list.name = "GetStatsOnlineIpListResponse"
    _add_field(ip_list, "name", 1, _TYPES.TYPE_STRING)
    _add_field(ip_list, "ips", 2, _TYPES.TYPE_MESSAGE,
               label=_REPEATED, type_name="IpEntry")

    users_request = file.message_type.add()
    users_request.name = "GetUsersStatsRequest"
    _add_field(users_request, "include_traffic", 1, _TYPES.TYPE_BOOL)
    _add_field(users_request, "reset", 2, _TYPES.TYPE_BOOL)

    online_ip = file.message_type.add()
    online_ip.name = "OnlineIPEntry"
    _add_field(online_ip, "ip", 1, _TYPES.TYPE_STRING)
    _add_field(online_ip, "last_seen", 2, _TYPES.TYPE_INT64)

    # field 3 upstream is TrafficUserStat; the panel always asks for
    # include_traffic=False (traffic accounting belongs to record_usages, and
    # reading those counters here would race with its resets), so it is left
    # undeclared and skipped as an unknown field.
    user_stat = file.message_type.add()
    user_stat.name = "UserStat"
    _add_field(user_stat, "email", 1, _TYPES.TYPE_STRING)
    _add_field(user_stat, "ips", 2, _TYPES.TYPE_MESSAGE,
               label=_REPEATED, type_name="OnlineIPEntry")

    users_response = file.message_type.add()
    users_response.name = "GetUsersStatsResponse"
    _add_field(users_response, "users", 1, _TYPES.TYPE_MESSAGE,
               label=_REPEATED, type_name="UserStat")

    all_online_request = file.message_type.add()
    all_online_request.name = "GetAllOnlineUsersRequest"

    all_online_response = file.message_type.add()
    all_online_response.name = "GetAllOnlineUsersResponse"
    _add_field(all_online_response, "users", 1, _TYPES.TYPE_STRING, label=_REPEATED)

    return file


def _class(name: str):
    descriptor = _POOL.FindMessageTypeByName(f"{_PACKAGE}.{name}")
    if _message_class is not None:
        return _message_class(descriptor)
    return message_factory.MessageFactory(_POOL).GetPrototype(descriptor)


_POOL.Add(_build_file())

GetStatsRequest = _class("GetStatsRequest")
GetStatsOnlineIpListResponse = _class("GetStatsOnlineIpListResponse")
GetUsersStatsRequest = _class("GetUsersStatsRequest")
GetUsersStatsResponse = _class("GetUsersStatsResponse")
GetAllOnlineUsersRequest = _class("GetAllOnlineUsersRequest")
GetAllOnlineUsersResponse = _class("GetAllOnlineUsersResponse")


def users_stats_callable(channel):
    """One RPC returning every user that currently has live connections."""
    return channel.unary_unary(
        GET_USERS_STATS_METHOD,
        request_serializer=GetUsersStatsRequest.SerializeToString,
        response_deserializer=GetUsersStatsResponse.FromString,
    )


def online_ip_list_callable(channel):
    """One RPC returning the online IPs of a single user."""
    return channel.unary_unary(
        GET_STATS_ONLINE_IP_LIST_METHOD,
        request_serializer=GetStatsRequest.SerializeToString,
        response_deserializer=GetStatsOnlineIpListResponse.FromString,
    )


def all_online_users_callable(channel):
    """One RPC returning the emails of every user with live connections."""
    return channel.unary_unary(
        GET_ALL_ONLINE_USERS_METHOD,
        request_serializer=GetAllOnlineUsersRequest.SerializeToString,
        response_deserializer=GetAllOnlineUsersResponse.FromString,
    )
