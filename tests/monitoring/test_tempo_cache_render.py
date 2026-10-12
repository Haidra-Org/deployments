"""Render and validate Tempo cache configurations without deploying services.

TEMPO_VERIFY_BINARY=/path/to/tempo-2.7.1 python3 -m unittest discover \
  -s tests/monitoring -p test_tempo_cache_render.py -v
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import jinja2
import yaml

ROLE = Path(__file__).resolve().parents[2] / "roles/horde_monitoring"


def context(**overrides):
    values = yaml.safe_load((ROLE / "defaults/main.yml").read_text())
    values.update(
        horde_monitoring_mimir_enable_s3=True,
        horde_monitoring_s3_endpoint="s3.example.invalid:8443",
        horde_monitoring_s3_access_key="GK00112233445566778899aabb",
        horde_monitoring_s3_secret_key="0" * 64,
        horde_monitoring_s3_region="garage",
        horde_monitoring_s3_insecure=False,
        horde_monitoring_s3_force_path_style=True,
    )
    values.update(overrides)
    return values


def render(values):
    env = jinja2.Environment(undefined=jinja2.StrictUndefined)
    env.filters["bool"] = bool
    env.filters["to_json"] = json.dumps
    return env.from_string((ROLE / "templates/tempo.yaml.j2").read_text()).render(values)


class TempoCacheRenderTest(unittest.TestCase):
    def test_default_s3_keeps_caching_disabled_and_worker_limit(self):
        config = yaml.safe_load(render(context()))
        self.assertNotIn("cache", config)
        self.assertEqual(config["storage"]["trace"]["pool"], {"max_workers": 400, "queue_depth": 20000})

    def test_staged_cache_and_worker_config(self):
        config = yaml.safe_load(render(context(
            horde_monitoring_tempo_cache_roles=["bloom", "parquet-footer"],
            horde_monitoring_tempo_cache_memcached_addresses="dns+memcached:11211",
            horde_monitoring_tempo_backend_max_workers=64,
        )))
        cache = config["cache"]["caches"][0]
        self.assertEqual(cache["roles"], ["bloom", "parquet-footer"])
        self.assertEqual(cache["memcached"]["addresses"], "dns+memcached:11211")
        self.assertNotIn("parquet-page", cache["roles"])
        self.assertEqual(config["storage"]["trace"]["pool"], {"max_workers": 64, "queue_depth": 20000})

    def test_local_storage_does_not_require_memcached(self):
        config = yaml.safe_load(render(context(horde_monitoring_mimir_enable_s3=False)))
        self.assertEqual(config["storage"]["trace"]["backend"], "local")
        self.assertNotIn("cache", config)

    def test_pinned_binary_accepts_default_staged_and_cache_only_configs(self):
        binary = os.environ.get("TEMPO_VERIFY_BINARY")
        if not binary:
            self.skipTest("Set TEMPO_VERIFY_BINARY to run the pinned-binary check")
        for s3, workers, roles in [(True, 400, []), (False, 400, []),
                                   (True, 400, ["bloom", "parquet-footer"]),
                                   (True, 64, ["bloom", "parquet-footer"])]:
            with self.subTest(s3=s3, workers=workers, roles=roles), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "tempo.yaml"
                path.write_text(render(context(
                    horde_monitoring_mimir_enable_s3=s3,
                    horde_monitoring_tempo_backend_max_workers=workers,
                    horde_monitoring_tempo_cache_roles=roles,
                    horde_monitoring_tempo_cache_memcached_addresses="dns+memcached:11211",
                )))
                result = subprocess.run([binary, f"-config.file={path}", "-config.verify=true"],
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def run_guards(self, **overrides):
        tasks = yaml.safe_load((ROLE / "tasks/tempo.yml").read_text())[:3]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guards.yml"
            path.write_text(yaml.safe_dump([{
                "hosts": "localhost", "connection": "local", "gather_facts": False,
                "vars": context(**overrides), "tasks": tasks,
            }]))
            return subprocess.run(["ansible-playbook", "-i", "localhost,", str(path)],
                                  capture_output=True, text=True, timeout=30)

    def test_guards_accept_disabled_and_enabled_cache(self):
        for overrides in [{}, {"horde_monitoring_tempo_cache_roles": ["bloom", "parquet-footer"],
                               "horde_monitoring_tempo_cache_memcached_addresses": "dns+memcached:11211",
                               "horde_monitoring_tempo_backend_max_workers": 64}]:
            result = self.run_guards(**overrides)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_guards_reject_unsafe_worker_and_cache_config(self):
        for overrides in [
            {"horde_monitoring_tempo_backend_max_workers": 0},
            {"horde_monitoring_tempo_backend_queue_depth": 1},
            {"horde_monitoring_tempo_cache_roles": ["bloom"]},
            {"horde_monitoring_tempo_cache_roles": ["unsupported"]},
            {"horde_monitoring_tempo_cache_roles": ["bloom", "bloom"]},
            {"horde_monitoring_tempo_cache_roles": "bloom"},
            {"horde_monitoring_tempo_cache_roles": ["bloom"],
             "horde_monitoring_tempo_cache_memcached_addresses": "dns+memcached:11211",
             "horde_monitoring_mimir_enable_memcached": False},
        ]:
            with self.subTest(overrides=overrides):
                result = self.run_guards(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('"evaluated_to": false', result.stdout)

    def test_intent_marker_reports_opt_in_configuration(self):
        task = yaml.safe_load((ROLE / "tasks/tempo.yml").read_text())[-1]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "marker.yml"
            path.write_text(yaml.safe_dump([{
                "hosts": "localhost", "connection": "local", "gather_facts": False,
                "vars": context(horde_monitoring_start_services=True,
                                horde_monitoring_tempo_read_tuning_textfile_dir=directory,
                                horde_monitoring_tempo_cache_roles=["bloom", "parquet-footer"],
                                horde_monitoring_tempo_backend_max_workers=64),
                "tasks": [task],
            }]))
            result = subprocess.run(["ansible-playbook", "-i", "localhost,", str(path)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            marker = (Path(directory) / "tempo_read_tuning.prom").read_text()
            self.assertIn("horde_tempo_cache_expected 1", marker)
            self.assertIn("horde_tempo_backend_max_workers 64", marker)


if __name__ == "__main__":
    unittest.main()
