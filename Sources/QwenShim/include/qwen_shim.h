#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/// llama.cpp 的薄层（Qwen3-ASR，design §32.2、D106）：Swift 只看得到这个标头，llama.h、ggml.h 不进 Swift
/// （whisper 的 XCFramework 也带一份不同版本的 ggml.h，两个同时 import 会撞类型）
typedef struct qwen_engine qwen_engine;

/// 回传 true 表示取消
typedef bool (*qwen_abort_fn)(void *user);

typedef struct {
    const char *context;      ///< 放进 system 消息的词汇表（Qwen3-ASR 的 contextual biasing），可以是 NULL
    const char *language;     ///< "Chinese"、"English"、"Japanese"：强制语言（assistant 先填「language X<asr_text>」）
    float repeat_penalty;     ///< 1.0 = 不加
    int32_t repeat_last_n;
    float temperature;        ///< 0 = greedy
    uint32_t seed;
    int32_t max_tokens;       ///< 最多生成几个 token
} qwen_params;

qwen_params qwen_params_default(void);

/// 加载语言模型和音频编码器（mmproj）。n_ctx：文字＋音频 token 的上限（30 秒音频约 375 个 token）。失败回传 NULL
qwen_engine *qwen_load(const char *model_path, const char *mmproj_path, int32_t n_ctx, int32_t n_threads, bool use_gpu);
void qwen_free(qwen_engine *engine);

/// 音频采样率（16000）
int32_t qwen_sample_rate(const qwen_engine *engine);

/// 转录一段 16 kHz 单声道浮点采样。输出 UTF-8 写进 out（最多 out_len - 1 个字节，一定补 NUL）。
/// 回传 0 成功、1 到达 max_tokens（可能在跳针）、-1 取消、其他负数是错误（-5 输出缓冲不够）。n_tokens 回传生成了几个 token（可以是 NULL）
int32_t qwen_transcribe(qwen_engine *engine, const float *samples, int32_t n_samples, const qwen_params *params,
                        qwen_abort_fn abort_cb, void *abort_user, char *out, int32_t out_len, int32_t *n_tokens);

/// llama.cpp 的系统信息（Metal、NEON…），写 log 用
const char *qwen_system_info(void);

#ifdef __cplusplus
}
#endif
