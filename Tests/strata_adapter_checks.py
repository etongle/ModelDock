"""Behavioral checks for independent Strata launches and auxiliary components."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('modeldock_strata', ROOT / 'Resources/strata.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class StrataAdapterChecks(unittest.TestCase):
    def test_sc117_preparation_keeps_filenames_and_rebuilds_private_pack(self):
        runtime = self.root / 'custom-runtime'
        (runtime / 'metal').mkdir(parents=True)
        (runtime / '.venv/bin').mkdir(parents=True)
        (runtime / '.venv/bin/python').symlink_to(sys.executable)
        (runtime / 'setup.py').write_text("FAMILIES={'qwen':{'hf':'original/{q}/','title':'original'}}\ndef write_config(*args): raise AssertionError('Unredirected config')\n")
        (runtime / 'metal/setup_mac.py').write_text('''import pathlib
import setup as S
def model_shard_names(model): return ['WRONG-ORIGINAL.gguf']
def main(argv):
    def arg(name): return argv[argv.index(name)+1]
    root=pathlib.Path(arg('--data-dir')); gguf=pathlib.Path(arg('--gguf-dir'))
    assert arg('--model') == 'Q2_0'
    assert 'SC117/' in S.FAMILIES['qwen']['hf']
    assert S.find_in([pathlib.Path('/shared-old-pack')], 'packs/q2_0') is None
    names=model_shard_names('Q2_0')
    assert all('GSQ-RCO-abliterated' in name for name in names)
    assert all((gguf/name).is_file() for name in names)
    pack=root/'packs/q2_0'; (pack/'tokenizer').mkdir(parents=True)
    (pack/'native_experts.txt').write_text('new-custom-offsets')
    (pack/'tokenizer/vocab.json').write_text('{}')
    cfg={'backend':'metal','args':['--native',str(gguf/names[0]),'--ple-gguf',str(gguf/names[1]),'--pack',str(pack),'--mtp',str(root/'mtp/rt')], 'tokenizer':str(pack/'tokenizer')}
    S.write_config(root/'wrong.json',cfg)
    return 0
''')
        (runtime.parent / 'modeldock-runtime.json').write_text(json.dumps({'revision': 'fixture-source'}))
        snapshot = self.root / 'SC117-snapshot'; gguf = snapshot / 'Q2_0'; gguf.mkdir(parents=True)
        for name in adapter.custom_shards('SC117-Q2_0'):
            (gguf / name).write_bytes(b'GGUF' + b'x' * 32)
        for name in ['mtp-q2_0.gguf', 'strata/rt/draft_vocab.bin']:
            item = snapshot / name; item.parent.mkdir(parents=True, exist_ok=True); item.write_bytes(b'fixture' * 8)
        target = self.root / 'custom-assembly'
        args = SimpleNamespace(runtime=str(runtime), data_dir=str(target), gguf_dir=str(gguf), model='SC117-Q2_0', vision='no', context=8192)
        with patch.object(adapter, 'preflight'):
            adapter.prepare(args)
        cfg = json.loads((target / 'strata.json').read_text())
        self.assertEqual(cfg['model_name'], adapter.SC117_REPO)
        self.assertEqual(Path(adapter.option(cfg['args'], '--native')).parent, gguf)
        self.assertTrue(Path(adapter.option(cfg['args'], '--pack')).is_relative_to(target))
        self.assertEqual((target / 'packs/q2_0/native_experts.txt').read_text(), 'new-custom-offsets')
        self.assertEqual(json.loads((target / 'modeldock-strata.json').read_text())['model'], 'SC117-Q2_0')

    def test_portable_environment_survives_app_replacement(self):
        portable = ROOT / 'build/ModelDock.app/Contents/Resources/PythonRuntime'
        if not (portable / 'bin/python3').exists():
            self.skipTest('Bundled portable runtime not present')
        source = self.root / 'portable-source'; source.mkdir()
        destination = self.root / 'independent-runtime'; destination.mkdir()
        python = adapter.private_environment(source, destination, portable)
        result = json.loads(subprocess.check_output([str(python), '-B', '-c', 'import sys,json;print(json.dumps({"base":sys.base_prefix,"exe":sys._base_executable}))'], text=True))
        self.assertTrue(Path(result['base']).is_relative_to(destination))
        self.assertTrue(Path(result['exe']).is_relative_to(destination))
        self.assertNotIn('ModelDock.app', result['base'])
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        for name in ('main.gguf', 'ngram.gguf', 'mtp/mtp-q2_0.gguf', 'vision.gguf',
                     'pack/native_experts.txt', 'pack/tokenizer/vocab.json',
                     'runtime/build-metal/strata', 'runtime/build-vision/bin/strata-vision'):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{}' if name.endswith('.json') else 'GGUF fixture')
        (self.root / 'mtp/rt').mkdir()
        self.config = {'backend': 'metal', 'exe': 'old-engine', 'cwd': 'old-source',
                       'tokenizer': str(self.root / 'pack/tokenizer'),
                       'args': ['--pack', str(self.root / 'pack'), '--native', str(self.root / 'main.gguf'),
                                '--ple-gguf', str(self.root / 'ngram.gguf'), '--mtp', str(self.root / 'mtp/rt'),
                                '--max-context', '32768', '--spec', '2', '--vision'],
                       'vision': {'exe': 'old-vision', 'mmproj': str(self.root / 'vision.gguf')},
                       'env': {'STRATA_METAL_STREAM': '0'}, 'model_name': 'fixture/flash-next'}

    def tearDown(self):
        self.temporary.cleanup()

    def launch(self, mode='automatic', draft='automatic', context=16384, speculation=2):
        return adapter.service_config(self.config, self.root / 'runtime', 29851, context, mode, draft, speculation)

    def test_independent_launch_preserves_original_config(self):
        original = copy.deepcopy(self.config)
        first = self.launch(context=8192)
        second = self.launch(context=65536)
        self.assertEqual(self.config, original)
        self.assertEqual(adapter.option(first['args'], '--max-context'), '8192')
        self.assertEqual(adapter.option(second['args'], '--max-context'), '65536')
        self.assertNotEqual(first['args'], second['args'])

    def test_text_launch_omits_vision_and_preserves_mtp(self):
        value = self.launch(mode='text')
        self.assertNotIn('vision', value)
        self.assertNotIn('--vision', value['args'])
        self.assertIn('--mtp', value['args'])

    def test_draft_disabled_runs_only_main_model(self):
        value = self.launch(draft='off')
        self.assertNotIn('--mtp', value['args'])
        self.assertEqual(adapter.option(value['args'], '--spec'), '1')
        self.assertIn('--ple-gguf', value['args'])

    def test_multimodal_rejects_text_assembly(self):
        del self.config['vision']
        with self.assertRaisesRegex(ValueError, 'no vision'):
            self.launch(mode='multimodal')

    def test_mtp_required_rejects_missing_draft(self):
        adapter.set_option(self.config['args'], '--mtp', None)
        with self.assertRaisesRegex(ValueError, 'no MTP'):
            self.launch(draft='on')

    def test_missing_ngram_prevents_launch(self):
        (self.root / 'ngram.gguf').unlink()
        with self.assertRaisesRegex(ValueError, 'ngram'):
            self.launch()

    def test_runtime_upgrade_rebinds_both_engines(self):
        value = self.launch(mode='multimodal')
        self.assertEqual(value['exe'], str(self.root / 'runtime/build-metal/strata'))
        self.assertEqual(value['vision']['exe'], str(self.root / 'runtime/build-vision/bin/strata-vision'))
        self.assertEqual(adapter.option(value['args'], '--native'), str(self.root / 'main.gguf'))

    def test_imported_hooks_credentials_and_replicas_are_not_executed(self):
        self.config.update(before_load='delete something', api_key='private', mcp_config='private.json', replicas=8)
        self.config['env']['DYLD_INSERT_LIBRARIES'] = '/tmp/anything.dylib'
        value = self.launch()
        for name in ('before_load', 'api_key', 'mcp_config', 'replicas'):
            self.assertNotIn(name, value)
        self.assertNotIn('DYLD_INSERT_LIBRARIES', value['env'])
        self.assertEqual(value['host'], '127.0.0.1')

    def test_duplicate_context_is_rejected(self):
        self.config['args'].extend(['--max-context', '1234'])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.launch()

    def test_wrong_backend_is_rejected(self):
        target = self.root / 'config.json'
        self.config['backend'] = 'cuda'
        target.write_text(json.dumps(self.config))
        with self.assertRaisesRegex(ValueError, 'Metal'):
            adapter.read_config(target)


if __name__ == '__main__':
    unittest.main()
