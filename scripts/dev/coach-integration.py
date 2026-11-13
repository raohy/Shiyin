#!/usr/bin/env python3
"""会中助手应用集成检查：隔离 bundle、SHIYIN_HOME、通知通道和本地假模型。

用法：python3 scripts/dev/coach-integration.py --app <隔离的 DEBUG .app> --ctl <shiyinctl>
测试 app 的 bundle id 必须不是 com.weiwei.shiyin。无需麦克风、真实模型或 API key。
"""
import argparse
import json
import os
import plistlib
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', required=True, type=Path)
parser.add_argument('--ctl', required=True, type=Path)
args = parser.parse_args()
bundle = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
assert bundle['CFBundleIdentifier'] != 'com.weiwei.shiyin', 'Use an isolated test bundle id'
root = Path(__file__).resolve().parents[2]
base = Path(tempfile.mkdtemp(prefix='shiyin-coach-integration-'))
home = base / 'home'
home.mkdir()
channel = 'com.weiwei.shiyin.coach-test.' + base.name
env = dict(os.environ, SHIYIN_DEBUG_CHANNEL=channel)
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
url = f'http://127.0.0.1:{port}'
server_log = (base / 'server.log').open('w')
requests_file = base / 'requests.jsonl'
server = subprocess.Popen(['python3', str(root / 'scripts/dev/fake-llm-server.py'), str(requests_file), str(port)],
                          stdout=server_log, stderr=server_log)
checks = 0


def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print('PASS', label, flush=True)


def wait(predicate, label, timeout=12):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = predicate()
        if value:
            return value
        time.sleep(.12)
    raise AssertionError('Timeout: ' + label)


def ctl(*parts):
    subprocess.run([str(args.ctl), *map(str, parts)], env=env, check=True, capture_output=True, timeout=8)


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def snapshot(mid):
    path = base / 'coach-state.json'
    path.unlink(missing_ok=True)
    ctl('coach', 'show', mid, path)
    return wait(lambda: read_json(path), 'coach state')


def wait_state(mid, predicate, label):
    def ready():
        state = snapshot(mid)
        return state if predicate(state) else None
    return wait(ready, label)


def launch(target_home=home, fake_cli=False):
    subprocess.run(['open', '-g', '-n', '--env', 'SHIYIN_HOME=' + str(target_home),
                    '--env', 'SHIYIN_DEBUG_CHANNEL=' + channel, str(args.app), '--args',
                    '-ApplePersistenceIgnoreState', 'YES', '-AppleLanguages', '(zh-Hans)',
                    '-hasCompletedOnboarding', 'YES', '-hasSeenGuide', 'YES', '-llmProvider', 'none',
                    '-autoSummarize', 'NO', '-correctTranscript', 'NO', '-diarize', 'NO',
                    '-liveTranscription', 'NO', '-compressAudio', 'NO', '-autoDetectLanguage', 'NO',
                    '-meetingDetection', 'NO', '-globalHotKey', 'NO', '-mcpEnabled', 'NO',
                    '-debugNoCLI', 'NO' if fake_cli else 'YES', '-debugToolDirectory', str(base / 'tools'),
                    '-debugCoachInterval', '0.5', '-debugCoachTimeout', '2'], check=True)
    path = base / 'ready.json'
    path.unlink(missing_ok=True)

    def ready():
        ctl('state', path)
        return read_json(path)
    wait(ready, 'app launch', timeout=20)


def quit_app():
    ctl('quit')
    time.sleep(.7)


def query(sql, parameters=(), target_home=home):
    with sqlite3.connect(f'file:{target_home}/shiyin.sqlite?mode=ro', uri=True) as connection:
        return connection.execute(sql, parameters).fetchall()


def preparation(title='供应商评审'):
    data = {'background': '讨论供应商交付范围', 'goals': '确认接口费用、日期和验收标准', 'role': '采购方',
            'initialQuestions': '验收标准是什么？', 'enabled': True}
    path = base / 'preparation.json'
    path.write_text(json.dumps(data, ensure_ascii=False))
    result = base / 'prepared.json'
    result.unlink(missing_ok=True)
    ctl('coach', 'prepare', title, path, result)
    return wait(lambda: read_json(result), 'save preparation')['id']


def requests():
    if not requests_file.exists():
        return []
    return [r for line in requests_file.read_text().splitlines()
            if (r := json.loads(line))['path'] == '/v1beta/interactions']


def mode(value):
    body = json.dumps(value).encode()
    with urllib.request.urlopen(urllib.request.Request(url + '/__mode', data=body,
                                headers={'Content-Type': 'application/json'}), timeout=3):
        pass


def response(seq, text='接口部分的費用和交付日期何時確認？', delay=0, **extra):
    mode(dict(responses={'coach': {'summary': '接口費用與交付範圍尚待確認。', 'questions': [
        {'text': text, 'reason': '接口需要單獨評估。', 'segment': seq, 'priority': 1}]}}, delay=delay, **extra))


try:
    def server_ready():
        try:
            mode({})
            return True
        except OSError:
            return False
    wait(server_ready, 'fake server HTTP')
    launch()
    mid = preparation()
    check(mid > 0 and query('SELECT source FROM meetings WHERE id=?', (mid,))[0][0] == 'prepared', '会前创建待录音会议')
    quit_app()
    launch()
    check(snapshot(mid)['state']['preparation']['goals'] == '确认接口费用、日期和验收标准', '会前资料重启保留')
    ctl('llmprovider', 'gemini', 'local-test-model')
    ctl('llmkey', 'gemini', 'local-test-key')
    ctl('llmurl', 'gemini', url)
    ctl('coach', 'start', mid)
    ctl('coach', 'append', mid, 10, '快稿错误：月底全部免费交付。')
    ctl('coach', 'analyze', mid)
    time.sleep(.7)  # 也等一次自动分析周期，确认不会消费快稿。
    s = snapshot(mid)
    check(not requests() and s['state']['nextSeq'] == 0, '只有快稿时手动与自动分析均不发送模型请求')
    ctl('coach', 'review', mid, 10, '月底交付，接口部分还需要单独评估。')
    s = wait_state(mid, lambda s: s['state']['nextSeq'] == 1, 'first analysis')
    check(len(s['state']['questions']) == 2 and '费用' in s['state']['questions'][1]['text'], '自动分析产生简体问题')
    check(s['state']['questions'][1]['time'] == 10, '问题时间来自音频复核稿')
    payload = json.loads(requests()[0]['body']['input'])
    check(payload['preparation']['role'] == '采购方' and payload['newTranscript'][0]['seq'] == 0, '模型收到目标角色和新增复核稿')
    check(payload['transcriptSource'] == 'audio_review' and '全部免费' not in json.dumps(payload, ensure_ascii=False), 'LLM 输入明确标注复核来源并排除快稿')
    count = len(requests())
    time.sleep(1.2)
    check(len(requests()) == count, '无新增内容不重复调用模型')
    question_id = s['state']['questions'][1]['id']
    ctl('coach', 'mark', mid, question_id, 'asked')
    response(1)
    ctl('coach', 'review', mid, 30, '接口费用的评估还没有确定时间。')
    s = wait_state(mid, lambda s: s['state']['nextSeq'] == 2, 'duplicate analysis')
    check(len(s['state']['questions']) == 2 and s['state']['questions'][1]['status'] == 'asked', '重复问题合并并保留已问状态')
    response(2, '验收失败后的整改期限如何约定？', delay=.8)
    previous_count = len(requests())
    ctl('coach', 'review', mid, 40, '验收失败时需要整改，但期限还没有约定。')
    wait_state(mid, lambda s: s['busy'], 'in-flight request')
    wait(lambda: len(requests()) > previous_count, 'request sent')
    before = len(requests())
    ctl('coach', 'analyze', mid)
    ctl('coach', 'mark', mid, s['state']['questions'][0]['id'], 'ignored')
    s = wait_state(mid, lambda s: s['state']['nextSeq'] == 3 and not s['busy'], 'concurrent merge')
    check(len(requests()) == before and len(s['state']['questions']) == 3, '分析请求不重叠')
    check(s['state']['questions'][0]['status'] == 'ignored', '响应合并保留分析期间用户的修改')
    ctl('coach', 'pause', mid)
    mode({'bad_key': True})
    ctl('coach', 'review', mid, 50, '还需要确认项目负责人。')
    ctl('coach', 'resume', mid)
    ctl('coach', 'analyze', mid)
    s = wait_state(mid, lambda s: not s['busy'] and '分析失败' in s['message'], 'provider failure')
    ctl('coach', 'pause', mid)
    check(s['state']['nextSeq'] == 3 and len(s['state']['questions']) == 3, '模型失败保留问题和分析游标')
    response(3, '项目负责人是谁？')
    ctl('coach', 'resume', mid)
    wait_state(mid, lambda s: s['state']['nextSeq'] == 4, 'retry failed batch')
    check(True, '失败后重试会处理同一批文字')
    ctl('coach', 'pause', mid)
    response(4, '是否需要额外采购资源？', delay=5)
    ctl('coach', 'review', mid, 60, '资源需要额外采购。')
    ctl('coach', 'resume', mid)
    wait_state(mid, lambda s: s['busy'], 'timeout request')
    ctl('coach', 'pause', mid)
    s = wait_state(mid, lambda s: not s['busy'] and '超时' in s['message'], 'analysis timeout')
    time.sleep(3.4)
    check(snapshot(mid)['state']['nextSeq'] == 4, '超时的迟到响应不能写入')
    response(4, '是否需要额外采购资源？', delay=.8)
    ctl('coach', 'resume', mid)
    wait_state(mid, lambda s: s['busy'], 'disable request')
    ctl('coach', 'enabled', mid, 0)
    time.sleep(1.1)
    check(snapshot(mid)['state']['nextSeq'] == 4, '关闭助手取消响应并保留游标')
    response(4, '是否需要额外采购资源？')
    ctl('coach', 'enabled', mid, 1)
    wait_state(mid, lambda s: s['state']['nextSeq'] == 5, 'enable retry')
    ctl('coach', 'pause', mid)
    count = len(requests())
    response(5, '接口文档由谁提供？')
    ctl('coach', 'review', mid, 70, '接口文档稍后提供。')
    time.sleep(1.1)
    check(len(requests()) == count, '暂停不发起自动分析')
    ctl('coach', 'resume', mid)
    wait_state(mid, lambda s: s['state']['nextSeq'] == 6, 'resume analysis')
    response(6, '测试环境什么时候开放？', delay=1)
    ctl('coach', 'review', mid, 80, '测试环境还没开放。')
    wait_state(mid, lambda s: s['busy'], 'stop request')
    ctl('coach', 'stop', mid)
    time.sleep(1.3)
    s = snapshot(mid)
    check(s['active'] == -1 and s['state']['nextSeq'] == 6, '停止录音后迟到响应不能写入')
    response(6, '测试环境什么时候开放？')
    ctl('coach', 'start', mid)
    wait_state(mid, lambda s: s['state']['nextSeq'] == 7, 'consume remaining text')
    ctl('coach', 'finish', mid)
    ctl('coach', 'open', mid)
    ctl('snapshot', base / 'questions-light.png', 'light', 'coach')
    ctl('snapshot', base / 'questions-dark.png', 'dark', 'coach')
    ctl('resummarize', mid)
    wait(lambda: query('SELECT notes FROM meetings WHERE id=?', (mid,))[0][0], 'final notes')
    check('Meeting preparation and suggested questions' in requests()[-1]['body']['input'], '会后整理带入目标与问题且不当成事实')
    saved = snapshot(mid)['state']
    quit_app()
    launch()
    check(snapshot(mid)['state'] == saved, '会后清单和问题状态重启保留')
    ctl('trash', mid)
    ctl('purge', mid)
    wait(lambda: not query('SELECT state FROM meeting_assistance WHERE meeting_id=?', (mid,)), 'cascade deletion')
    check(True, '删除会议级联清理助手数据')
    failure_id = preparation('录音失败保留准备')
    ctl('select', failure_id)
    ctl('record-sim', base / 'missing-audio.wav', 1, 0)
    wait(lambda: query('SELECT source FROM meetings WHERE id=?', (failure_id,))[0][0] == 'recording', 'recording started')
    check(snapshot(failure_id)['active'] == failure_id, '开始录音复用准备会议并启动助手')
    ctl('record', 'stop')
    wait(lambda: query('SELECT source FROM meetings WHERE id=?', (failure_id,))[0][0] == 'prepared', 'empty recording stopped')
    check(snapshot(failure_id)['state']['preparation']['goals'] == '确认接口费用、日期和验收标准', '未录到声音时保留同一场会前准备')
    ctl('coach', 'open', failure_id)
    ctl('snapshot', base / 'prepared.png', 'light', 'prepared')
    quit_app()
    upgrade_home = base / 'upgrade-home'
    upgrade_home.mkdir()
    with sqlite3.connect(home / 'shiyin.sqlite') as source, sqlite3.connect(upgrade_home / 'shiyin.sqlite') as target:
        source.backup(target)
        target.execute('DROP TABLE meeting_assistance')
        target.execute("DELETE FROM grdb_migrations WHERE identifier='v11'")
        target.execute("UPDATE meetings SET source='transcript'")
    launch(upgrade_home)
    check(bool(query("SELECT identifier FROM grdb_migrations WHERE identifier='v11'", target_home=upgrade_home))
          and bool(list((upgrade_home / 'backups').glob('*.sqlite'))), '旧数据库升级到 v11 前自动备份')
    quit_app()
    tools = base / 'tools'
    tools.mkdir()
    fake_cli = '''#!/usr/bin/env python3
import os,sys,time
from pathlib import Path
if '-p' not in sys.argv:
    print('{"loggedIn":true}')
    sys.exit(0)
sys.stdin.read()
(Path(os.environ['SHIYIN_HOME'])/'cli-pid.txt').write_text(str(os.getpid()))
time.sleep(20)
print('{"structured_output":{"summary":"fake","questions":[]}}')
'''
    for name in ['claude', 'codex']:
        executable = tools / name
        executable.write_text(fake_cli)
        executable.chmod(0o755)
    launch(fake_cli=True)
    cli_mid = preparation('本地假 CLI 取消检查')
    ctl('llmprovider', 'claude', '')
    ctl('coach', 'start', cli_mid)
    ctl('coach', 'review', cli_mid, 0, '需要确认接口范围。')
    pid_file = home / 'cli-pid.txt'
    pid = int(wait(lambda: pid_file.read_text() if pid_file.exists() else None, 'fake CLI start'))

    def terminated():
        try:
            os.kill(pid, 0)
            return False
        except ProcessLookupError:
            return True
    ctl('coach', 'stop', cli_mid)
    wait(terminated, 'CLI stopped')
    check(snapshot(cli_mid)['state']['nextSeq'] == 0, '停止助手会终止 CLI 子进程')
    pid_file.unlink()
    ctl('coach', 'start', cli_mid)
    pid = int(wait(lambda: pid_file.read_text() if pid_file.exists() else None, 'second fake CLI start'))
    ctl('coach', 'pause', cli_mid)
    wait_state(cli_mid, lambda s: '超时' in s['message'] and not s['busy'], 'CLI timeout')
    wait(terminated, 'CLI terminated after timeout')
    check(snapshot(cli_mid)['state']['nextSeq'] == 0, 'CLI 超时终止且保留待分析内容')
    print(f'应用集成检查通过：{checks} 项；测试结果：{base}', flush=True)
finally:
    try:
        quit_app()
    finally:
        server.terminate()
        server.wait(timeout=5)
        server_log.close()
        print('Test artifacts:', base, flush=True)
