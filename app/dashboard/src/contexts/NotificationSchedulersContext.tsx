import { useQuery } from "react-query";
import { fetch } from "service/http";
import { z } from "zod";
import { create } from "zustand";
import { useDashboard } from "./DashboardContext";

export const NotificationSchedulerSchema = z.object({
  id: z.number().nullable().optional(),
  name: z.string().min(1),
  webhook_url: z.string().min(1),
  secret_key: z.string().nullable().optional(),
  interval: z
    .number()
    .min(10)
    .or(z.string().transform((v) => parseInt(v, 10))),
  is_enabled: z.boolean(),
  include_users: z.boolean(),
  last_run_at: z.string().nullable().optional(),
  last_status: z.string().nullable().optional(),
  last_status_code: z.number().nullable().optional(),
  last_error: z.string().nullable().optional(),
  total_runs: z.number().nullable().optional(),
  failed_runs: z.number().nullable().optional(),
  created_at: z.string().nullable().optional(),
  updated_at: z.string().nullable().optional(),
});

export type NotificationSchedulerType = z.infer<
  typeof NotificationSchedulerSchema
>;

export const getSchedulerDefaultValues = (): NotificationSchedulerType => ({
  name: "",
  webhook_url: "",
  secret_key: "",
  interval: 60,
  is_enabled: true,
  include_users: true,
});

export const FetchSchedulersQueryKey = "fetch-notification-schedulers-query-key";

export type TriggerResult = {
  success: boolean;
  status_code: number | null;
  error: string | null;
};

export type NotificationSchedulerStore = {
  schedulers: NotificationSchedulerType[];
  fetchSchedulers: () => Promise<NotificationSchedulerType[]>;
  addScheduler: (scheduler: NotificationSchedulerType) => Promise<unknown>;
  updateScheduler: (scheduler: NotificationSchedulerType) => Promise<unknown>;
  deleteScheduler: () => Promise<unknown>;
  triggerScheduler: (
    scheduler: NotificationSchedulerType
  ) => Promise<TriggerResult>;
  deletingScheduler?: NotificationSchedulerType | null;
  setDeletingScheduler: (scheduler: NotificationSchedulerType | null) => void;
};

export const useSchedulersQuery = () => {
  const { isEditingNotifications } = useDashboard();
  return useQuery({
    queryKey: FetchSchedulersQueryKey,
    queryFn: useNotificationSchedulers.getState().fetchSchedulers,
    refetchInterval: isEditingNotifications ? 5000 : undefined,
    refetchOnWindowFocus: false,
    enabled: isEditingNotifications,
  });
};

export const useNotificationSchedulers = create<NotificationSchedulerStore>(
  (set, get) => ({
    schedulers: [],
    fetchSchedulers() {
      return fetch("/notification/schedulers").then((schedulers) => {
        set({ schedulers });
        return schedulers;
      });
    },
    addScheduler(body) {
      return fetch("/notification/schedulers", { method: "POST", body });
    },
    updateScheduler(body) {
      return fetch(`/notification/schedulers/${body.id}`, {
        method: "PUT",
        body,
      });
    },
    setDeletingScheduler(scheduler) {
      set({ deletingScheduler: scheduler });
    },
    deleteScheduler() {
      return fetch(
        `/notification/schedulers/${get().deletingScheduler?.id}`,
        {
          method: "DELETE",
        }
      );
    },
    triggerScheduler(body) {
      return fetch(`/notification/schedulers/${body.id}/trigger`, {
        method: "POST",
      });
    },
  })
);
