import typing
from dataclasses import dataclass, field

import grpc

from . import online
from .base import XRayBase
from .exceptions import NotSupportedError, RelatedError
from .proto.app.stats.command import command_pb2, command_pb2_grpc


@dataclass
class SysStatsResponse:
    num_goroutine: int
    num_gc: int
    alloc: int
    total_alloc: int
    sys: int
    mallocs: int
    frees: int
    live_objects: int
    pause_total_ns: int
    uptime: int


@dataclass
class StatResponse:
    name: str
    type: str
    link: str
    value: int


@dataclass
class UserStatsResponse:
    email: str
    uplink: int
    downlink: int


@dataclass
class InboundStatsResponse:
    tag: str
    uplink: int
    downlink: int


@dataclass
class OutboundStatsResponse:
    tag: str
    uplink: int
    downlink: int


@dataclass
class OnlineIp:
    ip: str
    last_seen: int  # unix seconds, as reported by the core


@dataclass
class UserOnlineStatsResponse:
    email: str
    ips: typing.List[OnlineIp] = field(default_factory=list)


class Stats(XRayBase):
    def _online_callable(self, name: str):
        """Lazily built multicallables for the online-IP RPCs (see online.py)."""
        cache = self.__dict__.setdefault("_online_callables", {})
        if name not in cache:
            factory = getattr(online, f"{name}_callable")
            cache[name] = factory(self._channel)
        return cache[name]

    def get_sys_stats(self, timeout: int = None) -> SysStatsResponse:
        try:
            stub = command_pb2_grpc.StatsServiceStub(self._channel)
            r = stub.GetSysStats(command_pb2.SysStatsRequest(), timeout=timeout)

        except grpc.RpcError as e:
            raise RelatedError(e)

        return SysStatsResponse(
            num_goroutine=r.NumGoroutine,
            num_gc=r.NumGC,
            alloc=r.Alloc,
            total_alloc=r.TotalAlloc,
            sys=r.Sys,
            mallocs=r.Mallocs,
            frees=r.Frees,
            live_objects=r.LiveObjects,
            pause_total_ns=r.PauseTotalNs,
            uptime=r.Uptime
        )

    def query_stats(self, pattern: str, reset: bool = False, timeout: int = None) -> typing.Iterable[StatResponse]:
        try:
            stub = command_pb2_grpc.StatsServiceStub(self._channel)
            r = stub.QueryStats(command_pb2.QueryStatsRequest(pattern=pattern, reset=reset), timeout=timeout)

        except grpc.RpcError as e:
            raise RelatedError(e)

        for stat in r.stat:
            type, name, _, link = stat.name.split('>>>')
            yield StatResponse(name, type, link, stat.value)

    def get_users_stats(self, reset: bool = False, timeout: int = None) -> typing.Iterable[StatResponse]:
        return self.query_stats("user>>>", reset=reset, timeout=timeout)

    def get_inbounds_stats(self, reset: bool = False, timeout: int = None) -> typing.Iterable[StatResponse]:
        return self.query_stats("inbound>>>", reset=reset, timeout=timeout)

    def get_outbounds_stats(self, reset: bool = False, timeout: int = None) -> typing.Iterable[StatResponse]:
        return self.query_stats("outbound>>>", reset=reset, timeout=timeout)

    def get_user_stats(self, email: str, reset: bool = False, timeout: int = None) -> typing.Iterable[StatResponse]:
        uplink, downlink = 0, 0
        for stat in self.query_stats(f"user>>>{email}>>>", reset=reset, timeout=timeout):
            if stat.link == 'uplink':
                uplink = stat.value
            if stat.link == 'downlink':
                downlink = stat.value

        return UserStatsResponse(email=email, uplink=uplink, downlink=downlink)

    def get_inbound_stats(self, tag: str, reset: bool = False, timeout: int = None) -> typing.Iterable[StatResponse]:
        uplink, downlink = 0, 0
        for stat in self.query_stats(f"inbound>>>{tag}>>>", reset=reset, timeout=timeout):
            if stat.link == 'uplink':
                uplink = stat.value
            if stat.link == 'downlink':
                downlink = stat.value
        return InboundStatsResponse(tag=tag, uplink=uplink, downlink=downlink)

    def get_outbound_stats(self, tag: str, reset: bool = False, timeout: int = None) -> typing.Iterable[StatResponse]:
        uplink, downlink = 0, 0
        for stat in self.query_stats(f"outbound>>>{tag}>>>", reset=reset, timeout=timeout):
            if stat.link == 'uplink':
                uplink = stat.value
            if stat.link == 'downlink':
                downlink = stat.value
        return OutboundStatsResponse(tag=tag, uplink=uplink, downlink=downlink)

    def get_users_online_stats(
        self, timeout: int = None
    ) -> typing.List[UserOnlineStatsResponse]:
        """Every user holding live connections right now, with its source IPs.

        A single RPC for the whole core. Requires `statsUserOnline` on the
        user's policy level and a core that implements `GetUsersStats`;
        older cores raise :class:`NotSupportedError`.
        """
        call = self._online_callable("users_stats")
        try:
            response = call(
                online.GetUsersStatsRequest(include_traffic=False, reset=False),
                timeout=timeout,
            )
        except grpc.RpcError as e:
            if e.code() == grpc.StatusCode.UNIMPLEMENTED:
                raise NotSupportedError(e.details() or "GetUsersStats is unavailable")
            raise RelatedError(e)

        return [
            UserOnlineStatsResponse(
                email=user.email,
                ips=[OnlineIp(ip=entry.ip, last_seen=entry.last_seen) for entry in user.ips],
            )
            for user in response.users
        ]

    def get_all_online_users(self, timeout: int = None) -> typing.List[str]:
        """Emails of every user holding live connections, without their IPs.

        Cheap middle ground for cores that know who is online but cannot
        report everything in one call: the caller probes only these users with
        :meth:`get_user_online_ips`. Cores older than the RPC raise
        :class:`NotSupportedError`.
        """
        call = self._online_callable("all_online_users")
        try:
            response = call(
                online.GetAllOnlineUsersRequest(), timeout=timeout
            )
        except grpc.RpcError as e:
            if e.code() == grpc.StatusCode.UNIMPLEMENTED:
                raise NotSupportedError(
                    e.details() or "GetAllOnlineUsers is unavailable"
                )
            raise RelatedError(e)

        return list(response.users)

    def get_user_online_ips(
        self, email: str, timeout: int = None
    ) -> typing.List[OnlineIp]:
        """Source IPs currently online for one user.

        Fallback for cores without the bulk `GetUsersStats` call. An unknown
        counter (user offline, or `statsUserOnline` not enabled) comes back as
        an empty list.
        """
        call = self._online_callable("online_ip_list")
        try:
            response = call(
                online.GetStatsRequest(name=f"user>>>{email}>>>online", reset=False),
                timeout=timeout,
            )
        except grpc.RpcError as e:
            if e.code() == grpc.StatusCode.UNIMPLEMENTED:
                raise NotSupportedError(
                    e.details() or "GetStatsOnlineIpList is unavailable"
                )
            if e.code() == grpc.StatusCode.NOT_FOUND:
                return []
            raise RelatedError(e)

        return [OnlineIp(ip=entry.key, last_seen=entry.value) for entry in response.ips]
