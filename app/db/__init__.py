from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from .base import Base, SessionLocal, engine  # noqa


class GetDB:  # Context Manager
    def __init__(self):
        self.db = SessionLocal()

    def __enter__(self):
        return self.db

    def __exit__(self, exc_type, exc_value, traceback):
        if isinstance(exc_value, SQLAlchemyError):
            self.db.rollback()  # rollback on exception

        self.db.close()


def get_db():  # Dependency
    with GetDB() as db:
        yield db


from .crud import (create_admin, create_notification_reminder,  # noqa
                   create_user, delete_notification_reminder, get_admin,
                   get_admins, get_jwt_secret_key, get_notification_reminder,
                   get_or_create_inbound, get_system_usage,
                   get_tls_certificate, get_user, get_user_by_id, get_users,
                   get_users_count, remove_admin, remove_user, revoke_user_sub,
                   set_owner, update_admin, update_user, update_user_status, reset_user_by_next,
                   update_user_sub, start_user_expire, get_admin_by_id,
                   get_admin_by_telegram_id,
                   create_notification_scheduler, get_notification_scheduler,
                   get_notification_schedulers, update_notification_scheduler,
                   delete_notification_scheduler, record_notification_scheduler_run,
                   get_anomaly_settings, update_anomaly_settings,
                   create_anomaly_scheduler, get_anomaly_scheduler,
                   get_anomaly_schedulers, update_anomaly_scheduler,
                   delete_anomaly_scheduler, record_anomaly_scheduler_run,
                   get_anomaly_clients, get_users_traffic,
                   get_recently_online_users,
                   count_online_users)

from .models import (JWT, System, User, NotificationScheduler,  # noqa
                     AnomalyScheduler, AnomalySettings)

__all__ = [
    "get_or_create_inbound",
    "get_user",
    "get_user_by_id",
    "get_users",
    "get_users_count",
    "create_user",
    "remove_user",
    "update_user",
    "update_user_status",
    "start_user_expire",
    "update_user_sub",
    "reset_user_by_next",
    "revoke_user_sub",
    "set_owner",
    "get_system_usage",
    "get_jwt_secret_key",
    "get_tls_certificate",
    "get_admin",
    "create_admin",
    "update_admin",
    "remove_admin",
    "get_admins",
    "get_admin_by_id",
    "get_admin_by_telegram_id",

    "create_notification_reminder",
    "get_notification_reminder",
    "delete_notification_reminder",

    "create_notification_scheduler",
    "get_notification_scheduler",
    "get_notification_schedulers",
    "update_notification_scheduler",
    "delete_notification_scheduler",
    "record_notification_scheduler_run",
    "count_online_users",

    "get_anomaly_settings",
    "update_anomaly_settings",
    "create_anomaly_scheduler",
    "get_anomaly_scheduler",
    "get_anomaly_schedulers",
    "update_anomaly_scheduler",
    "delete_anomaly_scheduler",
    "record_anomaly_scheduler_run",
    "get_anomaly_clients",
    "get_users_traffic",
    "get_recently_online_users",

    "GetDB",
    "get_db",

    "User",
    "System",
    "JWT",
    "NotificationScheduler",
    "AnomalyScheduler",
    "AnomalySettings",

    "Base",
    "Session",
]
