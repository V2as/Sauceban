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
  Spinner,
  Switch,
  Text,
  Tooltip,
  useToast,
  VStack,
} from "@chakra-ui/react";
import {
  BellAlertIcon,
  PaperAirplaneIcon,
  PlusIcon as HeroIconPlusIcon,
} from "@heroicons/react/24/outline";
import { zodResolver } from "@hookform/resolvers/zod";
import {
  FetchSchedulersQueryKey,
  getSchedulerDefaultValues,
  NotificationSchedulerSchema,
  NotificationSchedulerType,
  TriggerResult,
  useNotificationSchedulers,
  useSchedulersQuery,
} from "contexts/NotificationSchedulersContext";
import dayjs from "dayjs";
import { FC, ReactNode, useState } from "react";
import { Controller, useForm, UseFormReturn } from "react-hook-form";
import { useTranslation } from "react-i18next";
import {
  UseMutateFunction,
  useMutation,
  useQueryClient,
} from "react-query";
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

const ModalIcon = chakra(BellAlertIcon, {
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

const StatusBadge: FC<{ scheduler: NotificationSchedulerType }> = ({
  scheduler,
}) => {
  const { t } = useTranslation();
  if (!scheduler.is_enabled) {
    return (
      <Badge colorScheme="gray" rounded="full" px={3} py={1}>
        <Text fontSize="0.7rem" fontWeight="medium">
          {t("notifications.disabled")}
        </Text>
      </Badge>
    );
  }
  let colorScheme = "yellow";
  let label = t("notifications.pending");
  if (scheduler.last_status === "success") {
    colorScheme = "green";
    label = t("notifications.ok");
  } else if (scheduler.last_status === "failed") {
    colorScheme = "red";
    label = t("notifications.failed");
  }
  return (
    <Badge colorScheme={colorScheme} rounded="full" px={3} py={1}>
      <Text fontSize="0.7rem" fontWeight="medium">
        {label}
      </Text>
    </Badge>
  );
};

type SchedulerFormType = FC<{
  form: UseFormReturn<NotificationSchedulerType>;
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
            label={t("notifications.name")}
            size="sm"
            placeholder="Prometheus collector"
            {...form.register("name")}
            error={form.formState?.errors?.name?.message}
          />
        </FormControl>
        <FormControl>
          <CustomInput
            label={t("notifications.webhookUrl")}
            size="sm"
            placeholder="https://monitoring.example.com/push"
            {...form.register("webhook_url")}
            error={form.formState?.errors?.webhook_url?.message}
          />
        </FormControl>
        <FormControl>
          <CustomInput
            label={t("notifications.secretKey")}
            size="sm"
            type="password"
            placeholder={t("notifications.secretKeyPlaceholder")}
            {...form.register("secret_key")}
            error={form.formState?.errors?.secret_key?.message}
          />
        </FormControl>
        <FormControl>
          <FormLabel>{t("notifications.interval")}</FormLabel>
          <CustomInput
            size="sm"
            type="number"
            placeholder="60"
            endAdornment="s"
            {...form.register("interval", { valueAsNumber: true })}
            error={form.formState?.errors?.interval?.message}
          />
        </FormControl>
        <HStack w="full" justifyContent="space-between">
          <Controller
            name="include_users"
            control={form.control}
            render={({ field }) => (
              <FormControl display="flex" alignItems="center">
                <Switch
                  colorScheme="primary"
                  isChecked={!!field.value}
                  onChange={(e) => field.onChange(e.target.checked)}
                />
                <FormLabel mb="0" ml="2" fontSize="sm">
                  {t("notifications.includeUsers")}
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
                  {t("notifications.enabled")}
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
  scheduler: NotificationSchedulerType;
  toggleAccordion: () => void;
}> = ({ scheduler, toggleAccordion }) => {
  const { t } = useTranslation();
  const toast = useToast();
  const queryClient = useQueryClient();
  const { updateScheduler, setDeletingScheduler, triggerScheduler } =
    useNotificationSchedulers();
  const form = useForm<NotificationSchedulerType>({
    defaultValues: scheduler,
    resolver: zodResolver(NotificationSchedulerSchema),
  });

  const { isLoading, mutate } = useMutation(updateScheduler, {
    onSuccess: () => {
      generateSuccessMessage(t("notifications.editSuccess"), toast);
      queryClient.invalidateQueries(FetchSchedulersQueryKey);
    },
    onError: (e) => {
      generateErrorMessage(e, toast, form);
    },
  });

  const { isLoading: isTriggering, mutate: trigger } = useMutation(
    () => triggerScheduler(scheduler),
    {
      onSuccess: (res: TriggerResult) => {
        if (res.success) {
          generateSuccessMessage(
            t("notifications.triggerSuccess", { code: res.status_code }),
            toast
          );
        } else {
          generateErrorMessage(
            res.error || t("notifications.triggerFailed"),
            toast
          );
        }
        queryClient.invalidateQueries(FetchSchedulersQueryKey);
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
            <Badge colorScheme="blue" rounded="full" px={3} py={1}>
              <Text fontSize="0.7rem" fontWeight="medium">
                {scheduler.interval}s
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
            {t("notifications.lastRun")}:{" "}
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
          submitBtnText={t("notifications.editScheduler")}
          btnLeftAdornment={
            <HStack>
              <Tooltip label={t("delete")} placement="top">
                <IconButton
                  colorScheme="red"
                  variant="ghost"
                  size="sm"
                  aria-label="delete scheduler"
                  onClick={() => setDeletingScheduler(scheduler)}
                >
                  <DeleteIcon />
                </IconButton>
              </Tooltip>
              <Tooltip label={t("notifications.sendNow")} placement="top">
                <IconButton
                  colorScheme="blue"
                  variant="ghost"
                  size="sm"
                  aria-label="trigger scheduler"
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
  const { addScheduler } = useNotificationSchedulers();
  const form = useForm<NotificationSchedulerType>({
    resolver: zodResolver(NotificationSchedulerSchema),
    defaultValues: getSchedulerDefaultValues(),
  });
  const { isLoading, mutate } = useMutation(addScheduler, {
    onSuccess: () => {
      generateSuccessMessage(
        t("notifications.addSuccess", { name: form.getValues("name") }),
        toast
      );
      queryClient.invalidateQueries(FetchSchedulersQueryKey);
      form.reset(getSchedulerDefaultValues());
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
          <span>{t("notifications.addNewScheduler")}</span>
        </Text>
      </AccordionButton>
      <AccordionPanel px={2} py={4}>
        <SchedulerForm
          form={form}
          mutate={mutate}
          isLoading={isLoading}
          submitBtnText={t("notifications.addScheduler")}
          btnProps={{ variant: "solid" }}
        />
      </AccordionPanel>
    </AccordionItem>
  );
};

export const NotificationSettingsDialog: FC = () => {
  const { t } = useTranslation();
  const { isEditingNotifications, onEditingNotifications } = useDashboard();
  const { data: schedulers, isLoading } = useSchedulersQuery();
  const [openAccordions, setOpenAccordions] = useState<any>({});

  const onClose = () => {
    setOpenAccordions({});
    onEditingNotifications(false);
  };

  const toggleAccordion = (index: number | string) => {
    if (openAccordions[String(index)]) {
      delete openAccordions[String(index)];
    } else {
      openAccordions[String(index)] = {};
    }
    setOpenAccordions({ ...openAccordions });
  };

  return (
    <Modal isOpen={isEditingNotifications} onClose={onClose} size="2xl">
      <ModalOverlay bg="blackAlpha.300" backdropFilter="blur(10px)" />
      <ModalContent mx="3">
        <ModalHeader pt={6}>
          <HStack gap={2}>
            <ModalIcon color="primary" />
            <Text fontWeight="semibold" fontSize="lg">
              {t("notifications.title")}
            </Text>
          </HStack>
        </ModalHeader>
        <ModalCloseButton mt={3} />
        <ModalBody w="440px" pb={6} maxW="full">
          <Text mb={3} opacity={0.8} fontSize="sm">
            {t("notifications.description")}
          </Text>
          {isLoading ? (
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
