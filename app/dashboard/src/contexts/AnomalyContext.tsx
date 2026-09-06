import { useQuery } from "react-query";
import { fetch } from "service/http";
import { z } from "zod";
import { create } from "zustand";
import { useDashboard } from "./DashboardContext";

const asNumber = (min: number) =>
  z
    .number()
    .min(min)
    .or(z.string().transform((v) => parseFloat(v)));

export const AnomalySettingsSchema = z.object({
  is_enabled: z.boolean(),
  sample_interval: asNumber(5),
  window_seconds: asNumber(30),
  max_concurrent_networks: asNumber(0),
  max_subnets: asNumber(0),
  max_ips: asNumber(0),
  min_hits: asNumber(1),
  min_traffic_rate_mbps: asNumber(0),
  traffic_spike_ratio: asNumber(0),
  cooldown_seconds: asNumber(0),
  include_ips: z.boolean(),
  max_ips_in_report: asNumber(1),
});

export type AnomalySettingsType = z.infer<typeof AnomalySettingsSchema>;

export const AnomalySchedulerSchema = z.object({
  id: z.number().nullable().optional(),
  name: z.string().min(1),
  webhook_url: z.string().min(1),
  secret_key: z.string().nullable().optional(),
  interval: asNumber(5),
  is_enabled: z.boolean(),
  min_severity: z.string(),
  send_empty: z.boolean(),
  last_run_at: z.string().nullable().optional(),
  last_status: z.string().nullable().optional(),
  last_status_code: z.number().nullable().optional(),
  last_error: z.string().nullable().optional(),
  total_runs: z.number().nullable().optional(),
  failed_runs: z.number().nullable().optional(),
  total_anomalies_sent: z.number().nullable().optional(),
  created_at: z.string().nullable().optional(),
  updated_at: z.string().nullable().optional(),
});

export type AnomalySchedulerType = z.infer<typeof AnomalySchedulerSchema>;

export const SEVERITIES = ["low", "medium", "high", "critical"] as const;

export const getAnomalySchedulerDefaultValues = (): AnomalySchedulerType => ({
  name: "",
  webhook_url: "",
  secret_key: "",
  interval: 60,
  is_enabled: true,
  min_severity: "low",
  send_empty: false,
});

export type AnomalyReason = {
  rule: string;
  value: number;
  threshold: number;
};

export type AnomalyRecordType = {
  username: string;
  severity: string;
  score: number;
  suppressed: boolean;
  reasons: AnomalyReason[];
  evidence: {
    distinct_ips: number;
    distinct_subnets: number;
    peak_concurrent_ips: number;
    peak_concurrent_networks: number;
    ips: { ip: string; last_seen: number; network: string }[];
    nodes: string[];
    window_traffic_bytes: number;
    traffic_rate_mbps: number;
    traffic_ratio: number;
    hits: number;
  };
  client: {
    username: string;
    status?: string | null;
    admin?: string | null;
    sub_last_user_agent?: string | null;
  };
};

export type AnomalyReportType = {
  timestamp: number;
  monitor: {
    is_enabled: boolean;
    ip_source: string;
    tracked_users: number;
    users_online: number;
    nodes_sampled: string[];
    nodes_failed: string[];
    last_sample_at: number | null;
    last_error: string | null;
    warnings: string[];
  };
  summary: {
    anomalies_total: number;
    suppressed_total: number;
    by_severity: Record<string, number>;
    max_score: number;
  };
  anomalies: AnomalyRecordType[];
};

export const FetchAnomalySettingsQueryKey = "fetch-anomaly-settings-query-key";
export const FetchAnomalySchedulersQueryKey =
  "fetch-anomaly-schedulers-query-key";
export const FetchAnomalyReportQueryKey = "fetch-anomaly-report-query-key";

export type AnomalyTriggerResult = {
  success: boolean;
  status_code: number | null;
  error: string | null;
  anomalies_sent: number;
};

export type AnomalyStore = {
  settings?: AnomalySettingsType | null;
  schedulers: AnomalySchedulerType[];
  report?: AnomalyReportType | null;
  fetchSettings: () => Promise<AnomalySettingsType>;
  updateSettings: (settings: Partial<AnomalySettingsType>) => Promise<unknown>;
  fetchReport: () => Promise<AnomalyReportType>;
  fetchSchedulers: () => Promise<AnomalySchedulerType[]>;
  addScheduler: (scheduler: AnomalySchedulerType) => Promise<unknown>;
  updateScheduler: (scheduler: AnomalySchedulerType) => Promise<unknown>;
  deleteScheduler: () => Promise<unknown>;
  triggerScheduler: (
    scheduler: AnomalySchedulerType
  ) => Promise<AnomalyTriggerResult>;
  deletingScheduler?: AnomalySchedulerType | null;
  setDeletingScheduler: (scheduler: AnomalySchedulerType | null) => void;
};

export const useAnomaly = create<AnomalyStore>((set, get) => ({
  schedulers: [],
  fetchSettings() {
    return fetch("/anomaly/settings").then((settings) => {
      set({ settings });
      return settings;
    });
  },
  updateSettings(body) {
    return fetch("/anomaly/settings", { method: "PUT", body });
  },
  fetchReport() {
    return fetch("/anomaly/report").then((report) => {
      set({ report });
      return report;
    });
  },
  fetchSchedulers() {
    return fetch("/anomaly/schedulers").then((schedulers) => {
      set({ schedulers });
      return schedulers;
    });
  },
  addScheduler(body) {
    return fetch("/anomaly/schedulers", { method: "POST", body });
  },
  updateScheduler(body) {
    return fetch(`/anomaly/schedulers/${body.id}`, { method: "PUT", body });
  },
  setDeletingScheduler(scheduler) {
    set({ deletingScheduler: scheduler });
  },
  deleteScheduler() {
    return fetch(`/anomaly/schedulers/${get().deletingScheduler?.id}`, {
      method: "DELETE",
    });
  },
  triggerScheduler(body) {
    return fetch(`/anomaly/schedulers/${body.id}/trigger`, { method: "POST" });
  },
}));

export const useAnomalySettingsQuery = () => {
  const { isEditingAnomaly } = useDashboard();
  return useQuery({
    queryKey: FetchAnomalySettingsQueryKey,
    queryFn: useAnomaly.getState().fetchSettings,
    refetchOnWindowFocus: false,
    enabled: isEditingAnomaly,
  });
};

export const useAnomalySchedulersQuery = () => {
  const { isEditingAnomaly } = useDashboard();
  return useQuery({
    queryKey: FetchAnomalySchedulersQueryKey,
    queryFn: useAnomaly.getState().fetchSchedulers,
    refetchInterval: isEditingAnomaly ? 5000 : undefined,
    refetchOnWindowFocus: false,
    enabled: isEditingAnomaly,
  });
};

export const useAnomalyReportQuery = () => {
  const { isEditingAnomaly } = useDashboard();
  return useQuery({
    queryKey: FetchAnomalyReportQueryKey,
    queryFn: useAnomaly.getState().fetchReport,
    refetchInterval: isEditingAnomaly ? 5000 : undefined,
    refetchOnWindowFocus: false,
    enabled: isEditingAnomaly,
  });
};
