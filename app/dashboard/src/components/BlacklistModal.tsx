import {
  Accordion,
  AccordionButton,
  AccordionIcon,
  AccordionItem,
  AccordionPanel,
  Alert,
  AlertIcon,
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
  NoSymbolIcon,
  PlusIcon as HeroIconPlusIcon,
} from "@heroicons/react/24/outline";
import { zodResolver } from "@hookform/resolvers/zod";
import {
  BlacklistEntrySchema,
  BlacklistEntryType,
  BlacklistStatusType,
  FetchBlacklistQueryKey,
  getBlacklistEntryDefaultValues,
  useBlacklist,
  useBlacklistQuery,
} from "contexts/BlacklistContext";
import dayjs from "dayjs";
import { FC, ReactNode, useEffect, useState } from "react";
import { Controller, useForm, UseFormReturn } from "react-hook-form";
import { useTranslation } from "react-i18next";
import { UseMutateFunction, useMutation, useQueryClient } from "react-query";
import { formatBytes } from "utils/formatByte";
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

const ModalIcon = chakra(NoSymbolIcon, {
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

const EnforcementAlert: FC<{ status?: BlacklistStatusType | null }> = ({
  status,
}) => {
  const { t } = useTranslation();
  if (!status) return null;

  if (!status.enforce) {
    return (
      <Alert status="info" rounded="md" mb={3} fontSize="sm">
        <AlertIcon />
        {t("blacklist.enforcementOff")}
      </Alert>
    );
  }
  if (!status.available) {
    return (
      <Alert status="warning" rounded="md" mb={3} fontSize="sm">
        <AlertIcon />
        <Box>
          <Text fontWeight="medium">{t("blacklist.enforcementBroken")}</Text>
          <Text opacity={0.9}>{status.unavailable_reason}</Text>
        </Box>
      </Alert>
    );
  }
  if (status.entries_total > 0 && status.ip_source === "unavailable") {
    return (
      <Alert status="warning" rounded="md" mb={3} fontSize="sm">
        <AlertIcon />
        {t("blacklist.noIpSource")}
      </Alert>
    );
  }
  return null;
};

type EntryFormType = FC<{
  form: UseFormReturn<BlacklistEntryType>;
  mutate: UseMutateFunction<unknown, unknown, any>;
  isLoading: boolean;
  submitBtnText: string;
  usernameField?: ReactNode;
  btnProps?: Partial<ButtonProps>;
  btnLeftAdornment?: ReactNode;
}>;

const EntryForm: EntryFormType = ({
  form,
  mutate,
  isLoading,
  submitBtnText,
  usernameField,
  btnProps = {},
  btnLeftAdornment,
}) => {
  const { t } = useTranslation();
  return (
    <form onSubmit={form.handleSubmit((v) => mutate(v))}>
      <VStack rowGap={3}>
        {usernameField}
        <Controller
          name="limit_mbps"
          control={form.control}
          render={({ field }) => (
            <FormControl>
              <FormLabel>{t("blacklist.limit")}</FormLabel>
              <CustomInput
                size="sm"
                type="number"
                placeholder="10"
                endAdornment={t("blacklist.mbps")}
                name={field.name}
                value={String(field.value ?? "")}
                // the stepper reports a string, the inner field a DOM event
                onChange={(v: any) =>
                  field.onChange(typeof v === "string" ? v : v?.target?.value)
                }
                onBlur={field.onBlur}
                error={form.formState?.errors?.limit_mbps?.message}
              />
            </FormControl>
          )}
        />
        <FormControl>
          <CustomInput
            label={t("blacklist.reason")}
            size="sm"
            placeholder={t("blacklist.reasonPlaceholder")}
            {...form.register("reason")}
            error={form.formState?.errors?.reason?.message}
          />
        </FormControl>
        <Controller
          name="is_enabled"
          control={form.control}
          render={({ field }) => (
            <FormControl display="flex" alignItems="center">
              <Switch
                colorScheme="primary"
                isChecked={!!field.value}
                onChange={(e) => field.onChange(e.target.checked)}
              />
              <FormLabel mb="0" ml="2" fontSize="sm">
                {t("blacklist.enabled")}
              </FormLabel>
            </FormControl>
          )}
        />
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

const EntryAccordion: FC<{
  entry: BlacklistEntryType;
  toggleAccordion: () => void;
}> = ({ entry, toggleAccordion }) => {
  const { t } = useTranslation();
  const toast = useToast();
  const queryClient = useQueryClient();
  const { updateEntry, setDeletingEntry } = useBlacklist();
  const form = useForm<BlacklistEntryType>({
    defaultValues: entry,
    resolver: zodResolver(BlacklistEntrySchema),
  });

  const { isLoading, mutate } = useMutation(updateEntry, {
    onSuccess: () => {
      generateSuccessMessage(
        t("blacklist.editSuccess", { name: entry.username }),
        toast
      );
      queryClient.invalidateQueries(FetchBlacklistQueryKey);
    },
    onError: (e) => {
      generateErrorMessage(e, toast, form);
    },
  });

  const activeIps = entry.active_ips || [];

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
            {entry.username}
          </Text>
          <HStack>
            {entry.source === "anomaly" && (
              <Tooltip
                label={t("blacklist.autoHint", {
                  until: entry.expires_at
                    ? dayjs(entry.expires_at + "Z").format("HH:mm")
                    : "",
                })}
                placement="top"
              >
                <Badge colorScheme="purple" rounded="full" px={3} py={1}>
                  <Text fontSize="0.7rem" fontWeight="medium">
                    {t("blacklist.auto")}
                  </Text>
                </Badge>
              </Tooltip>
            )}
            <Badge colorScheme="blue" rounded="full" px={3} py={1}>
              <Text fontSize="0.7rem" fontWeight="medium">
                {entry.limit_mbps} {t("blacklist.mbps")}
              </Text>
            </Badge>
            <Badge
              colorScheme={
                !entry.is_enabled ? "gray" : activeIps.length ? "green" : "yellow"
              }
              rounded="full"
              px={3}
              py={1}
            >
              <Text fontSize="0.7rem" fontWeight="medium">
                {!entry.is_enabled
                  ? t("blacklist.disabled")
                  : activeIps.length
                  ? t("blacklist.shaping", { count: activeIps.length })
                  : t("blacklist.idle")}
              </Text>
            </Badge>
          </HStack>
        </HStack>
        <AccordionIcon />
      </AccordionButton>
      <AccordionPanel px={2} pb={2}>
        {entry.source === "anomaly" && (
          <Text fontSize="xs" color="purple.400" mb={2}>
            {t("blacklist.autoOwnership")}
          </Text>
        )}
        {activeIps.length > 0 && (
          <Text
            fontSize="xs"
            color="gray.500"
            _dark={{ color: "gray.400" }}
            mb={2}
          >
            {t("blacklist.activeIps")}: {activeIps.join(", ")} —{" "}
            {formatBytes(entry.shaped_bytes || 0)} / {entry.dropped_packets || 0}{" "}
            {t("blacklist.drops")}
          </Text>
        )}
        <EntryForm
          form={form}
          mutate={mutate}
          isLoading={isLoading}
          submitBtnText={t("blacklist.editEntry")}
          btnLeftAdornment={
            <Tooltip label={t("delete")} placement="top">
              <IconButton
                colorScheme="red"
                variant="ghost"
                size="sm"
                aria-label="remove from blacklist"
                onClick={() => setDeletingEntry(entry)}
              >
                <DeleteIcon />
              </IconButton>
            </Tooltip>
          }
        />
      </AccordionPanel>
    </AccordionItem>
  );
};

const AddEntryForm: FC<{
  toggleAccordion: () => void;
  onAdded: () => void;
}> = ({ toggleAccordion, onAdded }) => {
  const { t } = useTranslation();
  const toast = useToast();
  const queryClient = useQueryClient();
  const { addEntry, searchUsernames } = useBlacklist();
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const form = useForm<BlacklistEntryType>({
    resolver: zodResolver(BlacklistEntrySchema),
    defaultValues: getBlacklistEntryDefaultValues(),
  });
  const username = form.watch("username");

  useEffect(() => {
    // the panel can hold thousands of users, so the picker asks the API for
    // matches instead of pulling the whole list into the modal
    const timer = setTimeout(
      () => searchUsernames(username || "").then(setSuggestions).catch(() => {}),
      300
    );
    return () => clearTimeout(timer);
  }, [username]);

  const { isLoading, mutate } = useMutation(addEntry, {
    onSuccess: () => {
      generateSuccessMessage(
        t("blacklist.addSuccess", { name: form.getValues("username") }),
        toast
      );
      queryClient.invalidateQueries(FetchBlacklistQueryKey);
      // the parent remounts this form: NumberInput keeps its own state and
      // would survive form.reset() with the previous limit still shown
      onAdded();
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
          <span>{t("blacklist.addNewEntry")}</span>
        </Text>
      </AccordionButton>
      <AccordionPanel px={2} py={4}>
        <EntryForm
          form={form}
          mutate={mutate}
          isLoading={isLoading}
          submitBtnText={t("blacklist.addEntry")}
          btnProps={{ variant: "solid" }}
          usernameField={
            <FormControl>
              <CustomInput
                label={t("blacklist.username")}
                size="sm"
                list="blacklist-username-options"
                placeholder={t("blacklist.usernamePlaceholder")}
                {...form.register("username")}
                error={form.formState?.errors?.username?.message}
              />
              <datalist id="blacklist-username-options">
                {suggestions.map((name) => (
                  <option key={name} value={name} />
                ))}
              </datalist>
            </FormControl>
          }
        />
      </AccordionPanel>
    </AccordionItem>
  );
};

export const BlacklistDialog: FC = () => {
  const { t } = useTranslation();
  const { isEditingBlacklist, onEditingBlacklist } = useDashboard();
  const { data: blacklist, isLoading } = useBlacklistQuery();
  const [openAccordions, setOpenAccordions] = useState<Record<string, boolean>>(
    {}
  );
  const [addFormKey, setAddFormKey] = useState(0);

  const onClose = () => {
    setOpenAccordions({});
    onEditingBlacklist(false);
  };

  const toggleAccordion = (key: string) => {
    setOpenAccordions((opened) => {
      const next = { ...opened };
      if (next[key]) delete next[key];
      else next[key] = true;
      return next;
    });
  };

  const entries = blacklist?.entries || [];
  // accordions are tracked by entry id, so adding or removing an entry does
  // not open a neighbour that took over the index
  const openIndexes = entries.reduce<number[]>((indexes, entry, index) => {
    if (openAccordions[String(entry.id)]) indexes.push(index);
    return indexes;
  }, []);
  if (openAccordions.add) openIndexes.push(entries.length);

  return (
    <Modal isOpen={isEditingBlacklist} onClose={onClose} size="2xl">
      <ModalOverlay bg="blackAlpha.300" backdropFilter="blur(10px)" />
      <ModalContent mx="3">
        <ModalHeader pt={6}>
          <HStack gap={2}>
            <ModalIcon color="primary" />
            <Text fontWeight="semibold" fontSize="lg">
              {t("blacklist.title")}
            </Text>
          </HStack>
        </ModalHeader>
        <ModalCloseButton mt={3} />
        <ModalBody w="440px" pb={6} maxW="full">
          <Text mb={3} opacity={0.8} fontSize="sm">
            {t("blacklist.description")}
          </Text>
          <EnforcementAlert status={blacklist?.status} />
          {isLoading ? (
            <HStack justifyContent="center" py={6}>
              <Spinner />
            </HStack>
          ) : (
            <Accordion w="full" allowToggle index={openIndexes}>
              <VStack w="full" rowGap={3}>
                {entries.map((entry) => (
                  <EntryAccordion
                    key={entry.id}
                    entry={entry}
                    toggleAccordion={() => toggleAccordion(String(entry.id))}
                  />
                ))}
                <AddEntryForm
                  key={addFormKey}
                  toggleAccordion={() => toggleAccordion("add")}
                  onAdded={() => {
                    setOpenAccordions({});
                    setAddFormKey((key) => key + 1);
                  }}
                />
              </VStack>
            </Accordion>
          )}
        </ModalBody>
      </ModalContent>
    </Modal>
  );
};
