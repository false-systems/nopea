defmodule Nopea.Drift do
  @moduledoc """
  Three-way drift detection for post-deploy verification.

  Compares three states:
  - **Last Applied**: What we last applied to the cluster
  - **Desired**: What the deploy spec declares
  - **Live**: What's actually in the K8s cluster

  Used after deploys to verify resources landed correctly.
  """

  require Logger

  @type diff_result ::
          :no_drift
          | {:git_change, map()}
          | {:manual_drift, map()}
          | {:conflict, map()}

  @k8s_managed_metadata_fields [
    "resourceVersion",
    "uid",
    "creationTimestamp",
    "generation",
    "managedFields",
    "selfLink",
    "namespace"
  ]

  @k8s_managed_annotations [
    "kubectl.kubernetes.io/last-applied-configuration",
    "deployment.kubernetes.io/revision"
  ]

  @spec normalize(map()) :: map()
  def normalize(manifest) when is_map(manifest) do
    manifest
    |> strip_status()
    |> strip_managed_metadata()
    |> strip_managed_annotations()
    |> strip_controller_managed_fields()
  end

  @spec three_way_diff(map(), map(), map()) :: diff_result()
  def three_way_diff(last_applied, desired, live) do
    norm_last = normalize(last_applied)
    norm_desired = normalize(desired)
    norm_live = normalize(live)

    last_hash = do_hash(norm_last)
    desired_hash = do_hash(norm_desired)
    live_hash = do_hash(norm_live)

    git_changed = desired_hash != last_hash
    manual_drift = live_hash != last_hash

    cond do
      not git_changed and not manual_drift ->
        :no_drift

      git_changed and not manual_drift ->
        {:git_change, %{from: last_hash, to: desired_hash}}

      not git_changed and manual_drift ->
        {:manual_drift, %{expected: last_hash, actual: live_hash}}

      git_changed and manual_drift ->
        {:conflict, %{last: last_hash, desired: desired_hash, live: live_hash}}
    end
  end

  @spec verify_manifest(String.t(), map(), keyword()) ::
          diff_result() | :new_resource | :needs_apply
  def verify_manifest(service, manifest, opts \\ []) do
    k8s_module = Keyword.get(opts, :k8s_module, Nopea.K8s)
    cache_module = Keyword.get(opts, :cache_module, Nopea.Cache)

    resource_key = Nopea.Applier.resource_key(manifest)
    api_version = Map.fetch!(manifest, "apiVersion")
    kind = Map.fetch!(manifest, "kind")
    name = get_in(manifest, ["metadata", "name"])
    namespace = get_in(manifest, ["metadata", "namespace"]) || "default"

    last_applied_result = cache_module.get_last_applied(service, resource_key)
    live_result = k8s_module.get_resource(api_version, kind, name, namespace)

    case {last_applied_result, live_result} do
      {{:error, :not_found}, {:error, _}} -> :new_resource
      {{:error, :not_found}, {:ok, _live}} -> :needs_apply
      {{:ok, _last}, {:error, _}} -> :new_resource
      {{:ok, last_applied}, {:ok, live}} -> three_way_diff(last_applied, manifest, live)
    end
  end

  @spec compute_hash(map()) :: {:ok, String.t()} | {:error, term()}
  def compute_hash(manifest) do
    normalized = normalize(manifest)
    {:ok, "sha256:#{do_hash(normalized)}"}
  end

  # Private functions

  defp strip_status(manifest), do: Map.delete(manifest, "status")

  defp strip_managed_metadata(manifest) do
    case Map.get(manifest, "metadata") do
      nil -> manifest
      metadata -> Map.put(manifest, "metadata", Map.drop(metadata, @k8s_managed_metadata_fields))
    end
  end

  defp strip_managed_annotations(manifest) do
    case get_in(manifest, ["metadata", "annotations"]) do
      nil ->
        manifest

      annotations ->
        cleaned = Map.drop(annotations, @k8s_managed_annotations)

        if map_size(cleaned) == 0 do
          update_in(manifest, ["metadata"], &Map.delete(&1, "annotations"))
        else
          put_in(manifest, ["metadata", "annotations"], cleaned)
        end
    end
  end

  defp strip_controller_managed_fields(manifest) do
    case Map.get(manifest, "kind") do
      "Deployment" -> strip_deployment_defaults(manifest)
      "Service" -> strip_service_defaults(manifest)
      _ -> manifest
    end
  end

  defp strip_deployment_defaults(manifest) do
    manifest
    |> update_in(["spec"], &Map.drop(&1 || %{}, ["replicas"]))
    |> strip_rolling_update_defaults()
    |> strip_pod_spec_defaults()
  end

  defp strip_service_defaults(manifest) do
    update_in(manifest, ["spec"], fn spec ->
      Map.drop(spec || %{}, [
        "clusterIP",
        "clusterIPs",
        "internalTrafficPolicy",
        "ipFamilies",
        "ipFamilyPolicy",
        "sessionAffinity"
      ])
    end)
  end

  defp strip_rolling_update_defaults(manifest) do
    case get_in(manifest, ["spec", "strategy", "rollingUpdate"]) do
      nil -> manifest
      ru -> put_in(manifest, ["spec", "strategy", "rollingUpdate"], Map.drop(ru, ["maxSurge"]))
    end
  end

  defp strip_pod_spec_defaults(manifest) do
    path = ["spec", "template", "spec"]

    case get_in(manifest, path) do
      nil ->
        manifest

      pod_spec ->
        cleaned =
          pod_spec
          |> Map.drop([
            "dnsPolicy",
            "restartPolicy",
            "schedulerName",
            "securityContext",
            "terminationGracePeriodSeconds"
          ])
          |> strip_container_defaults()

        put_in(manifest, path, cleaned)
    end
  end

  defp strip_container_defaults(pod_spec) do
    case Map.get(pod_spec, "containers") do
      nil ->
        pod_spec

      containers ->
        cleaned =
          Enum.map(containers, fn c ->
            c
            |> Map.drop(["terminationMessagePath", "terminationMessagePolicy"])
            |> strip_probe_defaults("livenessProbe")
            |> strip_probe_defaults("readinessProbe")
            |> normalize_cpu_values()
          end)

        Map.put(pod_spec, "containers", cleaned)
    end
  end

  defp strip_probe_defaults(container, key) do
    case Map.get(container, key) do
      nil ->
        container

      probe ->
        Map.put(
          container,
          key,
          Map.drop(probe, ["failureThreshold", "periodSeconds", "successThreshold"])
        )
    end
  end

  defp normalize_cpu_values(container) do
    case get_in(container, ["resources", "limits", "cpu"]) do
      cpu when is_binary(cpu) ->
        put_in(container, ["resources", "limits", "cpu"], normalize_cpu(cpu))

      _ ->
        container
    end
  end

  defp normalize_cpu(cpu) do
    if String.ends_with?(cpu, "m") do
      millicores = String.trim_trailing(cpu, "m") |> String.to_integer()
      if rem(millicores, 1000) == 0, do: Integer.to_string(div(millicores, 1000)), else: cpu
    else
      cpu
    end
  end

  defp do_hash(normalized_manifest) do
    json =
      case Jason.encode(normalized_manifest, pretty: false) do
        {:ok, encoded} -> encoded
        {:error, _} -> inspect(normalized_manifest)
      end

    :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
  end
end
