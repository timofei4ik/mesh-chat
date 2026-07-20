from __future__ import annotations

import argparse
import sys
import unittest


RELIABILITY_TESTS = (
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_live_mutations_fan_out_to_every_online_account_device",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_direct_history_and_deletion_survive_device_change",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_offline_direct_message_and_file_sync_to_new_device",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_file_transfer_v2_resumes_after_restart_and_syncs_from_disk",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_file_transfer_v2_checksum_reset_and_cancel",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_secret_text_photo_and_file_restore_then_stay_deleted",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_story_media_reactions_and_views_follow_account_devices",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_group_owner_permissions_and_membership_survive_relogin",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_channel_history_files_reactions_and_member_leave",
    "server.tests.test_sync_integration.ServerSyncIntegrationTests."
    "test_sticker_library_is_account_scoped_across_devices",
    "server.tests.test_sync_v2_contract.SyncV2ContractTests."
    "test_interrupted_delta_replays_same_range_without_cursor_ack",
    "server.tests.test_sync_v2_contract.SyncV2ContractTests."
    "test_two_device_delta_soak_matches_snapshot_after_replays",
    "server.tests.test_ops.ServerOperationsTests."
    "test_reliability_audit_detects_media_and_backup_corruption",
    "server.tests.test_ops.ServerOperationsTests."
    "test_verified_backup_can_be_restored_and_is_rotated",
)


def main():
    parser = argparse.ArgumentParser(description="Run the MeshChat release reliability gate")
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    rounds = max(1, args.rounds)

    for round_index in range(rounds):
        if rounds > 1:
            print(f"Reliability round {round_index + 1}/{rounds}", flush=True)
        suite = unittest.defaultTestLoader.loadTestsFromNames(RELIABILITY_TESTS)
        result = unittest.TextTestRunner(
            verbosity=1 if args.quiet else 2,
        ).run(suite)
        if not result.wasSuccessful():
            raise SystemExit(1)
    print(f"Reliability gate passed ({rounds} round(s)).", flush=True)
    raise SystemExit(0)


if __name__ == "__main__":
    sys.path.insert(0, "")
    main()
