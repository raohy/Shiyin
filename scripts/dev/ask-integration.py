#!/usr/bin/env python3
"""隔离应用与本地假 LLM 验证提问的即时反馈、进展、完成、失败和取消。

python3 scripts/dev/ask-integration.py --app <隔离 DEBUG .app> --ctl <shiyinctl>
"""
import argparse
import json
import os
import plistlib
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', required=True, type=Path)
parser.add_argument('--ctl', required=True, type=Path)
args = parser.parse_args()
assert plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'] != 'com.weiwei.shiyin'
root = Path(__file__).resolve().parents[2]
base = Path(tempfile.mkdtemp(prefix='shiyin-ask-integration-'))
home = base / 'home'
home.mkdir()
channel = 'com.weiwei.shiyin.ask-test.' + base.name
env = dict(os.environ, SHIYIN_DEBUG_CHANNEL=channel)
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
url = f'http://127.0.0.1:{port}'
server_log = (base / 'server.log').open('w')
server = subprocess.Popen(['python3', str(root / 'scripts/dev/fake-llm-server.py'), str(base / 'requests.jsonl'), str(port)],
                          stdout=server_log, stderr=server_log)
checks = 0


def check(condition, label):
    global checks
    assert condition, label
    checks += 1
    print('PASS', label, flush=True)


def wait(predicate, label, timeout=15):
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


def state(target):
    path = base / 'questions.json'
    path.unlink(missing_ok=True)
    ctl('questions', target, path)
    return wait(lambda: read_json(path), 'question state')


def wait_state(target, predicate, label):
    def ready():
        value = state(target)
        return value if predicate(value) else None
    return wait(ready, label)


def mode(value):
    data = json.dumps(value).encode()
    with urllib.request.urlopen(urllib.request.Request(url + '/__mode', data=data,
                                headers={'Content-Type': 'application/json'}), timeout=3):
        return True


def server_ready():
    try:
        return mode({})
    except OSError:
        return False


def fixture(title):
    prep = base / 'preparation.json'
    prep.write_text(json.dumps({'background': '交付评审', 'goals': '确认负责人和日期', 'role': '',
                               'initialQuestions': '', 'enabled': False}, ensure_ascii=False))
    result = base / 'meeting.json'
    result.unlink(missing_ok=True)
    ctl('coach', 'prepare', title, prep, result)
    mid = wait(lambda: read_json(result), 'meeting fixture')['id']
    ctl('coach', 'review', mid, 5, '交付计划由小王负责，周五完成。')
    ctl('coach', 'finish', mid)
    return mid


try:
    wait(server_ready, 'local fake LLM')
    subprocess.run(['open', '-g', '-n', '--env', 'SHIYIN_HOME=' + str(home), '--env', 'SHIYIN_DEBUG_CHANNEL=' + channel,
                    str(args.app), '--args', '-ApplePersistenceIgnoreState', 'YES', '-AppleLanguages', '(zh-Hans)',
                    '-hasCompletedOnboarding', 'YES', '-hasSeenGuide', 'YES', '-llmProvider', 'none', '-autoSummarize', 'NO',
                    '-correctTranscript', 'NO', '-diarize', 'NO', '-liveTranscription', 'NO', '-compressAudio', 'NO',
                    '-autoDetectLanguage', 'NO', '-meetingDetection', 'NO', '-globalHotKey', 'NO', '-mcpEnabled', 'NO',
                    '-debugNoCLI', 'YES'], check=True)
    ready_file = base / 'ready.json'
    def ready():
        ctl('state', ready_file)
        return read_json(ready_file)
    wait(ready, 'isolated app launch', timeout=20)
    mid = fixture('交付计划会议')
    other = fixture('另一场会议')
    ctl('llmprovider', 'gemini', 'local-test-model')
    ctl('llmkey', 'gemini', 'local-test-key')
    ctl('llmurl', 'gemini', url)

    mode({'delay': 3})
    question = '交付计划由谁负责？'
    ctl('ask', mid, question)
    pending = state(mid)
    check(pending['pendingQuestion'] == question and pending['asking'] and not pending['questions'], '提交后立即显示问题，尚未完成时不伪造回答')
    check(pending['progress'] and pending['phase'] in ['preparing', 'answering'], '等待期间显示实际处理阶段')
    ctl('tab', 'ask')
    ctl('snapshot', base / 'pending-light.png', 'light', 'detail')
    ctl('snapshot', base / 'pending-dark.png', 'dark', 'detail')
    ctl('ask', mid, '忙碌时重复提交的问题')
    check(state(mid)['pendingQuestion'] == question, '重复提交不会覆盖正在处理的问题')
    completed = wait_state(mid, lambda s: not s['asking'] and len(s['questions']) == 1, 'completed answer')
    check(not completed['pendingQuestion'] and completed['questions'][0]['question'] == question
          and completed['questions'][0]['answer']['citations'], '完成后显示完整问题、回答和出处，并移除等待卡片')
    ctl('snapshot', base / 'completed.png', 'light', 'detail')

    mode({'bad_key': True})
    failed_question = '费用是否已经确认？'
    ctl('ask', mid, failed_question)
    failed = wait_state(mid, lambda s: not s['asking'] and s['phase'].startswith('failed'), 'failed answer')
    check(failed['pendingQuestion'] == failed_question and len(failed['questions']) == 1, '回答失败保留原问题和错误，不保存空回答')
    ctl('snapshot', base / 'failed.png', 'light', 'detail')
    mode({})
    ctl('retryask')
    retried = wait_state(mid, lambda s: not s['asking'] and len(s['questions']) == 2, 'retried answer')
    check(retried['questions'][-1]['question'] == failed_question, '重试沿用原问题并只保存一次成功结果')

    mode({'delay': 3})
    cancelled_question = '验收标准是什么？'
    ctl('ask', mid, cancelled_question)
    wait_state(mid, lambda s: s['phase'] == 'answering', 'request in flight')
    ctl('cancelask')
    cancelled = wait_state(mid, lambda s: not s['asking'] and s['phase'] == 'cancelled', 'cancelled answer')
    check(cancelled['pendingQuestion'] == cancelled_question and len(cancelled['questions']) == 2, '取消后保留问题，可重试且不写入空答案')
    time.sleep(3.2)
    check(len(state(mid)['questions']) == 2 and state(mid)['phase'] == 'cancelled', '取消后的迟到回答不能覆盖状态或新增记录')

    mode({'delay': 2, 'responses': {'keywords': {'keywords': ['交付']}}})
    ctl('askall', 'all', '交付计划有哪些？')
    wait_state('all', lambda s: s['phase'] == 'keywords', 'keyword progress')
    check(state('all')['pendingQuestion'] == '交付计划有哪些？', '跨会议提问也立即显示原问题与关键词提取进展')
    wait_state('all', lambda s: s['phase'] == 'answering', 'answer progress after search')
    check('分析' in state('all')['progress'], '搜索结束后进入回答生成阶段')
    wait_state('all', lambda s: not s['asking'] and len(s['questions']) == 1, 'cross-meeting answer')
    check(not state('all')['pendingQuestion'], '跨会议完整回答替换等待状态')

    ctl('folder', mid, '客户甲')
    ctl('folder', other, '客户乙')
    ctl('folderfilter', '客户甲')
    ctl('askall', 'folder', '交付由谁负责？')
    wait_state('all', lambda s: s['phase'] == 'keywords', 'folder request in flight')
    ctl('cancelask')
    wait_state('all', lambda s: not s['asking'], 'cancelled folder request')
    ctl('folderfilter', '客户乙')
    mode({'responses': {'keywords': {'keywords': ['交付']}}})
    ctl('retryask')
    scoped = wait_state('all', lambda s: not s['asking'] and len(s['questions']) == 2, 'retried folder request')
    check(scoped['questions'][-1]['answer']['meetingIds'] == [mid], '切换文件夹后重试仍使用原提问的搜索范围')

    mode({'delay': 2})
    ctl('ask', mid, '最后决定的日期是什么？')
    ctl('select', other)
    ctl('tab', 'ask')
    check(not state(other)['pendingQuestion'], '切换会议不会显示另一场会议的待处理问题')
    wait_state(mid, lambda s: not s['asking'] and len(s['questions']) == 3, 'answer completes in original meeting')
    check(not state(other)['visibleQuestions'], '旧会议回答完成后不会污染当前会议的问答列表')
    print(f'提问集成检查通过：{checks} 项；测试结果：{base}', flush=True)
finally:
    try:
        ctl('quit')
    finally:
        server.terminate()
        server.wait(timeout=5)
        server_log.close()
        print('Test artifacts:', base, flush=True)
