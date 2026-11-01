# Preserve every inherited setting; only immediate source lineage may change.
def settings:
  del(.source_mode, .source_commit, .parent_copr_build, .parent_source_commit,
      .parent_srpm_sha256, .parent_composition, .usb_role_pm_patch,
      .observed_runtime_teardown_cause);
(settings == ($parent[0] | settings))
and .adaptation_patch_count == 122
and .capture_channels == 4 and .capture_channel_counts == [1,2,4]
and .lmh_policy_ready_fix == true
and .vrr_opt_in_floor_hz == 30 and .vrr_ceiling_hz == 144
and .vrr_default_enabled == false
and .physical_acceptance == false
and .usb_role_pm_patch == "patches/usb/0001-qcom-system-role-pm.patch"
and .observed_runtime_teardown_cause == "unverified"
