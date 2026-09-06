import {
  Accordion,
  AccordionButton,
  AccordionIcon,
  AccordionItem,
  AccordionPanel,
  Badge,
  Box,
  Button,
  ButtonProps,
  chakra,
  FormControl,
  FormLabel,
  HStack,
  IconButton,
  Modal,
  ModalBody,
  ModalCloseButton,
  ModalContent,
  ModalHeader,
  ModalOverlay,
  Select,
  SimpleGrid,
  Spinner,
  Switch,
  Text,
  Tooltip,
  useToast,
  VStack,
} from "@chakra-ui/react";
import {
  ExclamationTriangleIcon,
  PaperAirplaneIcon,
  PlusIcon as HeroIconPlusIcon,
} from "@heroicons/react/24/outline";
import { zodResolver } from "@hookform/resolvers/zod";
import {
  AnomalyRecordType,
  AnomalySchedulerSchema,
  AnomalySchedulerType,
  AnomalySettingsType,
  AnomalyTriggerResult,
  FetchAnomalyReportQueryKey,
  FetchAnomalySchedulersQueryKey,
  FetchAnomalySettingsQueryKey,
  getAnomalySchedulerDefaultValues,
  SEVERITIES,
  useAnomaly,
  useAnomalyReportQuery,
  useAnomalySchedulersQuery,
  useAnomalySettingsQuery,
} from "contexts/AnomalyContext";
import dayjs from "dayjs";
import { FC, ReactNode, useEffect, useState } from "react";
import { Controller, useForm, UseFormReturn } from "react-hook-form";
import { useTranslation } from "react-i18next";
import { UseMutateFunction, useMutation, useQueryClient } from "react-query";
import {
  generateErrorMessage,
  generateSuccessMessage,
} from "utils/toastHandler";
import { useDashboard } from "../contexts/DashboardContext";
import { DeleteIcon } from "./DeleteUserModal";
import { Input } from "./Input";

const CustomInput = chakra(Input, {
  baseStyle: {
    bg: "white",
    _dark: {
      bg: "gray.700",
    },
  },
});

const ModalIcon = chakra(ExclamationTriangleIcon, {
  baseStyle: {
    w: 5,
    h: 5,
  },
});

const PlusIcon = chakra(HeroIconPlusIcon, {
  baseStyle: {
    w: 5,
    h: 5,
    strokeWidth: 2,
  },
});

const SendIcon = chakra(PaperAirplaneIcon, {
  baseStyle: {
    w: 4,
    h: 4,
  },
});

const SEVERITY_COLORS: Record<string, string> = {
  low: "gray",
  medium: "yellow",
  high: "orange",
  critical: "red",
};

const StatusBadge: FC<{ scheduler: AnomalySchedulerType }> = ({
  scheduler,
}) => {
  const { t } = useTranslation();
  if (!scheduler.is_enabled) {
    return (
      <Badge colorScheme="gray" rounded="full" px={3} py={1}>
        <Text fontSize="0.7rem" fontWeight="medium">
          {t("anomaly.disabled")}
        </Text>
      </Badge>
    );
  }
  let colorScheme = "yellow";
  let label = t("anomaly.pending");
  if (scheduler.last_status === "success") {
    colorScheme = "green";
    label = t("anomaly.ok");
  } else if (scheduler.last_status === "failed") {
    colorScheme = "red";
    label = t("anomaly.failed");
  }
  return (
    <Badge colorScheme={colorScheme} rounded="full" px={3} py={1}>
      <Text fontSize="0.7rem" fontWeight="medium">
        {label}
      </Text>
    </Badge>
  );
};

const MonitorSwitch: FC<{ settings?: AnomalySettingsType | null }> = ({
  settings,
}) => {
  const { t } = useTranslation();
  const toast = useToast();
  const queryClient = useQueryClient();
  const { updateSettings } = useAnomaly();

  const { isLoading, mutate } = useMutation(
    (is_enabled: boolean) => updateSettings({ is_enabled }),
    {
      onSuccess: (_, is_enabled) => {
        generateSuccessMessage(
          t(is_enabled ? "anomaly.monitorEnabled" : "anomaly.monitorDisabled"),
          toast
        );
        queryClient.invalidateQueries(FetchAnomalySettingsQueryKey);
        queryClient.invalidateQueries(FetchAnomalyReportQueryKey);
      },
      onError: (e) => {
        generateErrorMessage(e, toast);
      },
    }
  );

  return (
    <FormControl display="flex" alignItems="center">
      <Switch
        colorScheme="primary"
        isChecked={!!settings?.is_enabled}
        isDisabled={isLoading || !settings}
        onChange={(e) => mutate(e.target.checked)}
      />
      <FormLabel mb="0" ml="2" fontSize="sm" fontWeight="medium">
        {t("anomaly.monitoring")}
      </FormLabel>
      {isLoading && <Spinner size="xs" />}
    </FormControl>
  );
};

const SettingsForm: FC<{ settings: AnomalySettingsType }> = ({ settings }) => {
  const { t } = useTranslation();
  const toast = useToast();
  const queryClient = useQueryClient();
  const { updateSettings } = useAnomaly();
  const form = useForm<AnomalySettingsType>({ defaultValues: settings });

  useEffect(() => {
    form.reset(settings);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(settings)]);

  const { isLoading, mutate } = useMutation(updateSettings, {
    onSuccess: () => {
      generateSuccessMessage(t("anomaly.settingsSaved"), toast);
      queryClient.invalidateQueries(FetchAnomalySettingsQueryKey);
      queryClient.invalidateQueries(FetchAnomalyReportQueryKey);
    },
    onError: (e) => {
      generateErrorMessage(e, toast, form);
    },
  });

  // the master switch lives outside this form, so `is_enabled` is deliberately
  // not part of the payload
  const submit = (v: AnomalySettingsType) =>
    mutate({
      sample_interval: v.sample_interval,
      window_seconds: v.window_seconds,
      max_concurrent_networks: v.max_concurrent_networks,
      max_subnets: v.max_subnets,
      max_ips: v.max_ips,
      min_hits: v.min_hits,
      min_traffic_rate_mbps: v.min_traffic_rate_mbps,
      traffic_spike_ratio: v.traffic_spike_ratio,
      cooldown_seconds: v.cooldown_seconds,
      include_ips: v.include_ips,
      max_ips_in_report: v.max_ips_in_report,
    });

  const numberField = (
    name: keyof AnomalySettingsType,
    label: string,
    unit?: string,
    step?: number
  ) => (
    <FormControl>
      <CustomInput
        label={label}
        size="sm"
        type="number"
        step={step}
        endAdornment={unit}
        {...form.register(name, { valueAsNumber: true })}
        error={(form.formState?.errors as any)?.[name]?.message}
      />
    </FormControl>
  );

  return (
    <form onSubmit={form.handleSubmit(submit)}>
      <VStack rowGap={3} alignItems="flex-start">
        <Text fontSize="xs" opacity={0.8}>
          {t("anomaly.thresholdsHint")}
        </Text>
        <SimpleGrid columns={{ base: 1, sm: 2 }} spacing={3} w="full">
          {numberField(
            "max_concurrent_networks",
            t("anomaly.maxConcurrentNetworks")
          )}
          {numberField("max_subnets", t("anomaly.maxSubnets"))}
          {numberField("max_ips", t("anomaly.maxIps"))}
          {numberField("min_hits", t("anomaly.minHits"))}
          {numberField(
            "min_traffic_rate_mbps",
            t("anomaly.minTrafficRate"),
            "Mbps",
            0.1
          )}
          {numberField(
            "traffic_spike_ratio",
            t("anomaly.spikeRatio"),
            "x",
            0.1
          )}
          {numberField("sample_interval", t("anomaly.sampleInterval"), "s")}
          {numberField("window_seconds", t("anomaly.window"), "s")}
          {numberField("cooldown_seconds", t("anomaly.cooldown"), "s")}
          {numberField("max_ips_in_report", t("anomaly.maxIpsInReport"))}
        </SimpleGrid>
        <Controller
          name="include_ips"
          control={form.control}
          render={({ field }) => (
            <FormControl display="flex" alignItems="center">
              <Switch
                colorScheme="primary"
                isChecked={!!field.value}
                onChange={(e) => field.onChange(e.target.checked)}
              />
              <FormLabel mb="0" ml="2" fontSize="sm">
                {t("anomaly.includeIps")}
              </FormLabel>
            </FormControl>
          )}
        />
        <HStack w="full" justifyContent="flex-end" pt={1}>
          <Button
            type="submit"
            size="sm"
            colorScheme="primary"
            isLoading={isLoading}
          >
            {t("anomaly.saveSettings")}
          </Button>
        </HStack>
      </VStack>
    </form>
  );
};

const AnomalyRow: FC<{ record: AnomalyRecordType }> = ({ record }) => {
  const { t } = useTranslation();
  const evidence = record.evidence;
  return (
    <Box
      w="full"
      border="1px solid"
      _dark={{ borderColor: "gray.600" }}
      _light={{ borderColor: "gray.200" }}
      borderRadius="4px"
      px={3}
      py={2}
    >
      <HStack justifyContent="space-between" alignItems="flex-start">
        <VStack alignItems="flex-start" spacing={0}>
          <HStack>
            <Text fontSize="sm" fontWeight="medium">
              {record.username}
            </Text>
            <Badge
              colorScheme={SEVERITY_COLORS[record.severity] || "gray"}
              rounded="full"
              px={2}
            >
              <Text fontSize="0.65rem">
                {t(`anomaly.severity.${record.severity}`)}
              </Text>
            </Badge>
            {record.suppressed && (
              <Tooltip label={t("anomaly.suppressedHint")} placement="top">
                <Badge colorScheme="purple" rounded="full" px={2}>
                  <Text fontSize="0.65rem">{t("anomaly.suppressed")}</Text>
                </Badge>
              </Tooltip>
            )}
          </HStack>
          <Text fontSize="xs" color="gray.500" _dark={{ color: "gray.400" }}>
            {record.reasons.map((r) => t(`anomaly.rule.${r.rule}`)).join(", ")}
          </Text>
        </VStack>
        <VStack alignItems="flex-end" spacing={0}>
          <Text fontSize="xs" color="gray.500" _dark={{ color: "gray.400" }}>
            {t("anomaly.networksShort")}: {evidence.peak_concurrent_networks}/
            {evidence.distinct_subnets} · {t("anomaly.ipsShort")}:{" "}
            {evidence.distinct_ips}
          </Text>
          <Text fontSize="xs" color="gray.500" _dark={{ color: "gray.400" }}>
            {evidence.traffic_rate_mbps.toFixed(1)} Mbps · {t("anomaly.score")}:{" "}
            {record.score}
          </Text>
        </VStack>
      </HStack>
      {evidence.ips.length > 0 && (
        <Text
          mt={1}
          fontSize="xs"
          fontFamily="mono"
          color="gray.500"
          _dark={{ color: "gray.400" }}
          noOfLines={2}
        >
          {evidence.ips.map((i) => i.ip).join(", ")}
        </Text>
      )}
    </Box>
  );
};

type SchedulerFormType = FC<{
  form: UseFormReturn<AnomalySchedulerType>;
  mutate: UseMutateFunction<unknown, unknown, any>;
  isLoading: boolean;
  submitBtnText: string;
  btnProps?: Partial<ButtonProps>;
  btnLeftAdornment?: ReactNode;
}>;

const SchedulerForm: SchedulerFormType = ({
  form,
  mutate,
  isLoading,
  submitBtnText,
  btnProps = {},
  btnLeftAdornment,
}) => {
  const { t } = useTranslation();
  return (
    <form onSubmit={form.handleSubmit((v) => mutate(v))}>
      <VStack rowGap={3}>
        <FormControl>
          <CustomInput
            label={t("anomaly.name")}
            size="sm"
            placeholder="Abuse watcher"
            {...form.register("name")}
            error={form.formState?.errors?.name?.message}
          />
        </FormControl>
        <FormControl>
          <CustomInput
            label={t("anomaly.webhookUrl")}
            size="sm"
            placeholder="https://monitoring.example.com/anomalies"
            {...form.register("webhook_url")}
            error={form.formState?.errors?.webhook_url?.message}
          />
        </FormControl>
        <FormControl>
          <CustomInput
            label={t("anomaly.secretKey")}
            size="sm"
            type="password"
            placeholder={t("anomaly.secretKeyPlaceholder")}
            {...form.register("secret_key")}
            error={form.formState?.errors?.secret_key?.message}
          />
        </FormControl>
        <HStack w="full" alignItems="flex-end" gap={3}>
          <FormControl>
            <FormLabel fontSize="sm">{t("anomaly.minSeverity")}</FormLabel>
            <Select size="sm" {...form.register("min_severity")}>
              {SEVERITIES.map((severity) => (
                <option key={severity} value={severity}>
                  {t(`anomaly.severity.${severity}`)}
                </option>
              ))}
            </Select>
          </FormControl>
          <FormControl>
            <FormLabel fontSize="sm">{t("anomaly.minSpacing")}</FormLabel>
            <CustomInput
              size="sm"
              type="number"
              placeholder="60"
              endAdornment="s"
              {...form.register("interval", { valueAsNumber: true })}
              error={form.formState?.errors?.interval?.message}
            />
          </FormControl>
        </HStack>
        <HStack w="full" justifyContent="space-between">
          <Controller
            name="send_empty"
            control={form.control}
            render={({ field }) => (
              <FormControl display="flex" alignItems="center">
                <Switch
                  colorScheme="primary"
                  isChecked={!!field.value}
                  onChange={(e) => field.onChange(e.target.checked)}
                />
                <FormLabel mb="0" ml="2" fontSize="sm">
                  {t("anomaly.sendEmpty")}
                </FormLabel>
              </FormControl>
            )}
          />
          <Controller
            name="is_enabled"
            control={form.control}
            render={({ field }) => (
              <FormControl
                display="flex"
                alignItems="center"
                justifyContent="flex-end"
              >
                <Switch
                  colorScheme="primary"
                  isChecked={!!field.value}
                  onChange={(e) => field.onChange(e.target.checked)}
                />
                <FormLabel mb="0" ml="2" fontSize="sm">
                  {t("anomaly.enabled")}
                </FormLabel>
              </FormControl>
            )}
          />
        </HStack>
        <HStack w="full" justifyContent="space-between" pt={2}>
          <Box>{btnLeftAdornment}</Box>
          <Button
            type="submit"
            size="sm"
            colorScheme="primary"
            isLoading={isLoading}
            {...btnProps}
          >
            {submitBtnText}
          </Button>
        </HStack>
      </VStack>
    </form>
  );
};

const SchedulerAccordion: FC<{
  scheduler: AnomalySchedulerType;
  toggleAccordion: () => void;
}> = ({ scheduler, toggleAccordion }) => {
  const { t } = useTranslation();
  const toast = useToast();
  const queryClient = useQueryClient();
  const { updateScheduler, setDeletingScheduler, triggerScheduler } =
    useAnomaly();
  const form = useForm<AnomalySchedulerType>({
    defaultValues: scheduler,
    resolver: zodResolver(AnomalySchedulerSchema),
  });

  const { isLoading, mutate } = useMutation(updateScheduler, {
    onSuccess: () => {
      generateSuccessMessage(t("anomaly.editSuccess"), toast);
      queryClient.invalidateQueries(FetchAnomalySchedulersQueryKey);
    },
    onError: (e) => {
      generateErrorMessage(e, toast, form);
    },
  });

  const { isLoading: isTriggering, mutate: trigger } = useMutation(
    () => triggerScheduler(scheduler),
    {
      onSuccess: (res: AnomalyTriggerResult) => {
        if (res.success) {
          generateSuccessMessage(
            t("anomaly.triggerSuccess", {
              code: res.status_code,
              count: res.anomalies_sent,
            }),
            toast
          );
        } else {
          generateErrorMessage(res.error || t("anomaly.triggerFailed"), toast);
        }
        queryClient.invalidateQueries(FetchAnomalySchedulersQueryKey);
      },
      onError: (e) => {
        generateErrorMessage(e, toast);
      },
    }
  );

  return (
    <AccordionItem
      border="1px solid"
      _dark={{ borderColor: "gray.600" }}
      _light={{ borderColor: "gray.200" }}
      borderRadius="4px"
      p={1}
      w="full"
    >
      <AccordionButton px={2} borderRadius="3px" onClick={toggleAccordion}>
        <HStack w="full" justifyContent="space-between" pr={2}>
          <Text
            as="span"
            fontWeight="medium"
            fontSize="sm"
            flex="1"
            textAlign="left"
            color="gray.700"
            _dark={{ color: "gray.300" }}
          >
            {scheduler.name}
          </Text>
          <HStack>
            <Badge
              colorScheme={SEVERITY_COLORS[scheduler.min_severity] || "gray"}
              rounded="full"
              px={3}
              py={1}
            >
              <Text fontSize="0.7rem" fontWeight="medium">
                {t(`anomaly.severity.${scheduler.min_severity}`)}+
              </Text>
            </Badge>
            <StatusBadge scheduler={scheduler} />
          </HStack>
        </HStack>
        <AccordionIcon />
      </AccordionButton>
      <AccordionPanel px={2} pb={2}>
        {scheduler.last_run_at && (
          <Text
            fontSize="xs"
            color="gray.500"
            _dark={{ color: "gray.400" }}
            mb={2}
          >
            {t("anomaly.lastRun")}:{" "}
            {dayjs(scheduler.last_run_at).format("YYYY-MM-DD HH:mm:ss")}
            {scheduler.last_status === "failed" && scheduler.last_error
              ? ` — ${scheduler.last_error}`
              : ""}
          </Text>
        )}
        <SchedulerForm
          form={form}
          mutate={mutate}
          isLoading={isLoading}
          submitBtnText={t("anomaly.editScheduler")}
          btnLeftAdornment={
            <HStack>
              <Tooltip label={t("delete")} placement="top">
                <IconButton
                  colorScheme="red"
                  variant="ghost"
                  size="sm"
                  aria-label="delete anomaly webhook"
                  onClick={() => setDeletingScheduler(scheduler)}
                >
                  <DeleteIcon />
                </IconButton>
              </Tooltip>
              <Tooltip label={t("anomaly.sendNow")} placement="top">
                <IconButton
                  colorScheme="blue"
                  variant="ghost"
                  size="sm"
                  aria-label="trigger anomaly webhook"
                  isLoading={isTriggering}
                  onClick={() => trigger()}
                >
                  <SendIcon />
                </IconButton>
              </Tooltip>
            </HStack>
          }
        />
      </AccordionPanel>
    </AccordionItem>
  );
};

const AddSchedulerForm: FC<{
  toggleAccordion: () => void;
  resetAccordions: () => void;
}> = ({ toggleAccordion, resetAccordions }) => {
  const { t } = useTranslation();
  const toast = useToast();
  const queryClient = useQueryClient();
  const { addScheduler } = useAnomaly();
  const form = useForm<AnomalySchedulerType>({
    resolver: zodResolver(AnomalySchedulerSchema),
    defaultValues: getAnomalySchedulerDefaultValues(),
  });
  const { isLoading, mutate } = useMutation(addScheduler, {
    onSuccess: () => {
      generateSuccessMessage(
        t("anomaly.addSuccess", { name: form.getValues("name") }),
        toast
      );
      queryClient.invalidateQueries(FetchAnomalySchedulersQueryKey);
      form.reset(getAnomalySchedulerDefaultValues());
      resetAccordions();
    },
    onError: (e) => {
      generateErrorMessage(e, toast, form);
    },
  });
  return (
    <AccordionItem
      border="1px solid"
      _dark={{ borderColor: "gray.600" }}
      _light={{ borderColor: "gray.200" }}
      borderRadius="4px"
      p={1}
      w="full"
    >
      <AccordionButton px={2} borderRadius="3px" onClick={toggleAccordion}>
        <Text
          as="span"
          fontWeight="medium"
          fontSize="sm"
          flex="1"
          textAlign="left"
          color="gray.700"
          _dark={{ color: "gray.300" }}
          display="flex"
          gap={1}
        >
          <PlusIcon display="inline-block" />{" "}
          <span>{t("anomaly.addNewScheduler")}</span>
        </Text>
      </AccordionButton>
      <AccordionPanel px={2} py={4}>
        <SchedulerForm
          form={form}
          mutate={mutate}
          isLoading={isLoading}
          submitBtnText={t("anomaly.addScheduler")}
          btnProps={{ variant: "solid" }}
        />
      </AccordionPanel>
    </AccordionItem>
  );
};

export const AnomalySettingsDialog: FC = () => {
  const { t } = useTranslation();
  const { isEditingAnomaly, onEditingAnomaly } = useDashboard();
  const { data: settings, isLoading: settingsLoading } =
    useAnomalySettingsQuery();
  const { data: schedulers, isLoading } = useAnomalySchedulersQuery();
  const { data: report } = useAnomalyReportQuery();
  const [openAccordions, setOpenAccordions] = useState<any>({});

  const onClose = () => {
    setOpenAccordions({});
    onEditingAnomaly(false);
  };

  const toggleAccordion = (index: number | string) => {
    if (openAccordions[String(index)]) {
      delete openAccordions[String(index)];
    } else {
      openAccordions[String(index)] = {};
    }
    setOpenAccordions({ ...openAccordions });
  };

  const anomalies = report?.anomalies || [];
  const monitor = report?.monitor;

  return (
    <Modal isOpen={isEditingAnomaly} onClose={onClose} size="2xl">
      <ModalOverlay bg="blackAlpha.300" backdropFilter="blur(10px)" />
      <ModalContent mx="3">
        <ModalHeader pt={6}>
          <HStack gap={2}>
            <ModalIcon color="primary" />
            <Text fontWeight="semibold" fontSize="lg">
              {t("anomaly.title")}
            </Text>
          </HStack>
        </ModalHeader>
        <ModalCloseButton mt={3} />
        <ModalBody w="540px" pb={6} maxW="full">
          <Text mb={3} opacity={0.8} fontSize="sm">
            {t("anomaly.description")}
          </Text>

          <Box
            border="1px solid"
            _dark={{ borderColor: "gray.600" }}
            _light={{ borderColor: "gray.200" }}
            borderRadius="4px"
            px={3}
            py={2}
            mb={3}
          >
            <MonitorSwitch settings={settings} />
            {monitor && settings?.is_enabled && (
              <Text
                mt={1}
                fontSize="xs"
                color="gray.500"
                _dark={{ color: "gray.400" }}
              >
                {t("anomaly.source")}:{" "}
                {t(`anomaly.ipSource.${monitor.ip_source}`)}
                {" · "}
                {t("anomaly.onlineTracked")}: {monitor.users_online}/
                {monitor.tracked_users}
                {monitor.nodes_sampled.length > 0 &&
                  ` · ${monitor.nodes_sampled.join(", ")}`}
              </Text>
            )}
            {monitor?.warnings?.map((warning) => (
              <Text key={warning} mt={1} fontSize="xs" color="orange.400">
                {warning}
              </Text>
            ))}
          </Box>

          {settingsLoading || isLoading ? (
            <HStack justifyContent="center" py={6}>
              <Spinner />
            </HStack>
          ) : (
            <Accordion
              w="full"
              allowToggle
              index={Object.keys(openAccordions).map((i) => parseInt(i))}
            >
              <VStack w="full" rowGap={3}>
                <AccordionItem
                  border="1px solid"
                  _dark={{ borderColor: "gray.600" }}
                  _light={{ borderColor: "gray.200" }}
                  borderRadius="4px"
                  p={1}
                  w="full"
                >
                  <AccordionButton
                    px={2}
                    borderRadius="3px"
                    onClick={() => toggleAccordion("settings")}
                  >
                    <Text
                      as="span"
                      fontWeight="medium"
                      fontSize="sm"
                      flex="1"
                      textAlign="left"
                      color="gray.700"
                      _dark={{ color: "gray.300" }}
                    >
                      {t("anomaly.detectionSettings")}
                    </Text>
                    <AccordionIcon />
                  </AccordionButton>
                  <AccordionPanel px={2} pb={3}>
                    {settings && <SettingsForm settings={settings} />}
                  </AccordionPanel>
                </AccordionItem>

                <AccordionItem
                  border="1px solid"
                  _dark={{ borderColor: "gray.600" }}
                  _light={{ borderColor: "gray.200" }}
                  borderRadius="4px"
                  p={1}
                  w="full"
                >
                  <AccordionButton
                    px={2}
                    borderRadius="3px"
                    onClick={() => toggleAccordion("report")}
                  >
                    <HStack w="full" justifyContent="space-between" pr={2}>
                      <Text
                        as="span"
                        fontWeight="medium"
                        fontSize="sm"
                        flex="1"
                        textAlign="left"
                        color="gray.700"
                        _dark={{ color: "gray.300" }}
                      >
                        {t("anomaly.liveReport")}
                      </Text>
                      <Badge
                        colorScheme={anomalies.length ? "red" : "green"}
                        rounded="full"
                        px={3}
                        py={1}
                      >
                        <Text fontSize="0.7rem" fontWeight="medium">
                          {anomalies.length}
                        </Text>
                      </Badge>
                    </HStack>
                    <AccordionIcon />
                  </AccordionButton>
                  <AccordionPanel px={2} pb={3}>
                    {anomalies.length === 0 ? (
                      <Text fontSize="sm" opacity={0.7}>
                        {settings?.is_enabled
                          ? t("anomaly.noAnomalies")
                          : t("anomaly.monitorOffHint")}
                      </Text>
                    ) : (
                      <VStack w="full" rowGap={2}>
                        {anomalies.map((record) => (
                          <AnomalyRow key={record.username} record={record} />
                        ))}
                      </VStack>
                    )}
                  </AccordionPanel>
                </AccordionItem>

                {(schedulers || []).map((scheduler, index) => (
                  <SchedulerAccordion
                    key={scheduler.id}
                    scheduler={scheduler}
                    toggleAccordion={() => toggleAccordion(index)}
                  />
                ))}
                <AddSchedulerForm
                  toggleAccordion={() =>
                    toggleAccordion((schedulers || []).length)
                  }
                  resetAccordions={() => setOpenAccordions({})}
                />
              </VStack>
            </Accordion>
          )}
        </ModalBody>
      </ModalContent>
    </Modal>
  );
};
