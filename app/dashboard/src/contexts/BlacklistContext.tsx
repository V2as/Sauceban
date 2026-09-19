import { useQuery } from "react-query";
import { fetch } from "service/http";
import { z } from "zod";
import { create } from "zustand";
import { useDashboard } from "./DashboardContext";

export const BlacklistEntrySchema = z.object({
  username: z.string().min(1),
  limit_mbps: z.coerce.number().int().min(1),
  is_enabled: z.boolean(),
  reason: z.string().nullable().optional(),
});

export type BlacklistEntryType = z.infer<typeof BlacklistEntrySchema> & {
  id?: number | null;
  user_id?: number | null;
  active_ips?: string[];
  shaped_bytes?: number;
  dropped_packets?: number;
  // "manual" | "anomaly" — a cap the anomaly monitor installed expires by
  // itself, and editing it here makes it the operator's
  source?: string | null;
  expires_at?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
};

export type BlacklistStatusType = {
  enforce: boolean;
  available: boolean;
  unavailable_reason?: string | null;
  interface?: string | null;
  ip_source: string;
  entries_total: number;
  shaped_users: number;
  shaped_ips: number;
  last_sync_at?: number | null;
  last_applied_at?: number | null;
  last_error?: string | null;
};

export type BlacklistType = {
  entries: BlacklistEntryType[];
  status: BlacklistStatusType;
};

export const getBlacklistEntryDefaultValues = (): BlacklistEntryType => ({
  username: "",
  limit_mbps: 10,
  is_enabled: true,
  reason: "",
});

export const FetchBlacklistQueryKey = "fetch-blacklist-query-key";

export type BlacklistStore = {
  blacklist?: BlacklistType | null;
  fetchBlacklist: () => Promise<BlacklistType>;
  addEntry: (entry: BlacklistEntryType) => Promise<unknown>;
  updateEntry: (entry: BlacklistEntryType) => Promise<unknown>;
  deleteEntry: () => Promise<unknown>;
  deletingEntry?: BlacklistEntryType | null;
  setDeletingEntry: (entry: BlacklistEntryType | null) => void;
  searchUsernames: (search: string) => Promise<string[]>;
};

export const useBlacklist = create<BlacklistStore>((set, get) => ({
  fetchBlacklist() {
    return fetch("/blacklist").then((blacklist) => {
      set({ blacklist });
      return blacklist;
    });
  },
  addEntry(body) {
    return fetch("/blacklist", { method: "POST", body });
  },
  updateEntry(body) {
    return fetch(`/blacklist/${body.username}`, {
      method: "PUT",
      body: {
        limit_mbps: body.limit_mbps,
        is_enabled: body.is_enabled,
        reason: body.reason,
      },
    });
  },
  setDeletingEntry(entry) {
    set({ deletingEntry: entry });
  },
  deleteEntry() {
    return fetch(`/blacklist/${get().deletingEntry?.username}`, {
      method: "DELETE",
    });
  },
  searchUsernames(search) {
    return fetch("/users", { query: { search, limit: 10 } }).then(
      (res: { users: { username: string }[] }) =>
        (res.users || []).map((user) => user.username)
    );
  },
}));

export const useBlacklistQuery = () => {
  const { isEditingBlacklist } = useDashboard();
  return useQuery({
    queryKey: FetchBlacklistQueryKey,
    queryFn: useBlacklist.getState().fetchBlacklist,
    // the shaped-address list and the traffic counters move on their own
    refetchInterval: isEditingBlacklist ? 5000 : undefined,
    refetchOnWindowFocus: false,
    enabled: isEditingBlacklist,
  });
};
