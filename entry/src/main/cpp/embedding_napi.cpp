// SemSearch: NAPI wrapper around MNN embedding engine
// exposes: init(modelDir), embed(text) -> Float32Array(768), isLoaded(), prepareDir(path)
#include "napi/native_api.h"
#include "llm/llm.hpp"
#include <hilog/log.h>
#include <string>
#include <memory>
#include <sys/stat.h>
#include <errno.h>

using MNN::Transformer::Embedding;

static std::unique_ptr<Embedding> g_embedding;
static std::string g_model_dir; // dir passed to init()/initVisual(), for reload dedup
static constexpr int EMBED_DIM = 768;

#define LOG(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, 0x0000, "SemSearch", fmt, ##__VA_ARGS__)

// recursively mkdir -p then chmod 0777 so `hdc file send` (shell uid) can push model files in
static napi_value PrepareDir(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "prepareDir(path: string) requires 1 argument");
        return nullptr;
    }
    char dir[1024] = { 0 };
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[0], dir, sizeof(dir), &len) != napi_ok) {
        napi_throw_error(env, nullptr, "path must be a string");
        return nullptr;
    }
    std::string path(dir);
    // mkdir -p
    std::string cur;
    for (size_t i = 1; i <= path.size(); i++) {
        if (i == path.size() || path[i] == '/') {
            cur = path.substr(0, i);
            if (!cur.empty() && mkdir(cur.c_str(), 0777) != 0 && errno != EEXIST) {
                LOG("mkdir %{public}s failed: %{public}d", cur.c_str(), errno);
                napi_value result = nullptr;
                napi_get_boolean(env, false, &result);
                return result;
            }
        }
    }
    bool ok = chmod(path.c_str(), 0777) == 0;
    LOG("prepareDir %{public}s chmod: %{public}d", path.c_str(), ok ? 1 : 0);
    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

static napi_value IsLoaded(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_get_boolean(env, g_embedding != nullptr, &result);
    return result;
}

static napi_value Init(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "init(modelDir: string) requires 1 argument");
        return nullptr;
    }
    char dir[1024] = { 0 };
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[0], dir, sizeof(dir), &len) != napi_ok) {
        napi_throw_error(env, nullptr, "modelDir must be a string");
        return nullptr;
    }
    std::string config = std::string(dir) + "/config.json";
    LOG("init embedding model: %{public}s", config.c_str());
    auto* embedding = Embedding::createEmbedding(config, true);
    if (embedding == nullptr) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }
    g_embedding.reset(embedding);
    g_model_dir = dir;
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

// Load the multimodal model dir (visual.mnn + embedding config, Omni path).
// If the requested dir is already loaded (e.g. init() pointed at the same
// eg2v_int8 dir), returns true without rebuilding the engine instance.
static napi_value InitVisual(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "initVisual(modelDir: string) requires 1 argument");
        return nullptr;
    }
    char dir[1024] = { 0 };
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[0], dir, sizeof(dir), &len) != napi_ok) {
        napi_throw_error(env, nullptr, "modelDir must be a string");
        return nullptr;
    }
    if (g_embedding != nullptr && g_model_dir == dir) {
        LOG("initVisual: %{public}s already loaded", dir);
        napi_value result = nullptr;
        napi_get_boolean(env, true, &result);
        return result;
    }
    std::string config = std::string(dir) + "/config.json";
    LOG("init visual model: %{public}s", config.c_str());
    auto* embedding = Embedding::createEmbedding(config, true);
    if (embedding == nullptr) {
        napi_value result = nullptr;
        napi_get_boolean(env, false, &result);
        return result;
    }
    g_embedding.reset(embedding);
    g_model_dir = dir;
    napi_value result = nullptr;
    napi_get_boolean(env, true, &result);
    return result;
}

// image file (absolute path in app sandbox) -> 768-dim embedding.
// Synchronous: called once per photo during background indexing.
static napi_value ImgEmbed(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || g_embedding == nullptr) {
        napi_throw_error(env, nullptr, "model not initialized");
        return nullptr;
    }
    size_t path_len = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &path_len) != napi_ok) {
        napi_throw_error(env, nullptr, "imagePath must be a string");
        return nullptr;
    }
    std::string path(path_len, '\0');
    if (napi_get_value_string_utf8(env, args[0], path.data(), path_len + 1, &path_len) != napi_ok) {
        napi_throw_error(env, nullptr, "read imagePath failed");
        return nullptr;
    }
    auto vec = g_embedding->img_embedding(path);
    if (vec == nullptr) {
        napi_throw_error(env, nullptr, "img_embedding failed (visual model not loaded or image decode failed)");
        return nullptr;
    }
    auto* data = vec->readMap<float>();
    auto size = vec->getInfo()->size;
    if (size > EMBED_DIM) {
        size = EMBED_DIM;
    }
    napi_value out = nullptr;
    void* buffer = nullptr;
    napi_create_arraybuffer(env, size * sizeof(float), &buffer, &out);
    memcpy(buffer, data, size * sizeof(float));
    napi_value typed = nullptr;
    napi_create_typedarray(env, napi_float32_array, size, out, 0, &typed);
    return typed;
}

static napi_value Embed(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1 || g_embedding == nullptr) {
        napi_throw_error(env, nullptr, "model not initialized");
        return nullptr;
    }
    size_t text_len = 0;
    if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &text_len) != napi_ok) {
        napi_throw_error(env, nullptr, "text must be a string");
        return nullptr;
    }
    std::string text(text_len, '\0');
    if (napi_get_value_string_utf8(env, args[0], text.data(), text_len + 1, &text_len) != napi_ok) {
        napi_throw_error(env, nullptr, "read text failed");
        return nullptr;
    }
    auto vec = g_embedding->txt_embedding(text);
    if (vec == nullptr) {
        napi_throw_error(env, nullptr, "txt_embedding failed");
        return nullptr;
    }
    auto* data = vec->readMap<float>();
    auto size = vec->getInfo()->size;
    if (size > EMBED_DIM) {
        size = EMBED_DIM;
    }
    napi_value out = nullptr;
    void* buffer = nullptr;
    napi_create_arraybuffer(env, size * sizeof(float), &buffer, &out);
    memcpy(buffer, data, size * sizeof(float));
    napi_value typed = nullptr;
    napi_create_typedarray(env, napi_float32_array, size, out, 0, &typed);
    return typed;
}

static napi_value EmbedDoc(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2 || g_embedding == nullptr) {
        napi_throw_error(env, nullptr, "model not initialized / embedDoc(title, text) requires 2 args");
        return nullptr;
    }
    char title[512] = { 0 };
    char text[65536] = { 0 };
    size_t len = 0;
    if (napi_get_value_string_utf8(env, args[0], title, sizeof(title), &len) != napi_ok ||
        napi_get_value_string_utf8(env, args[1], text, sizeof(text), &len) != napi_ok) {
        napi_throw_error(env, nullptr, "title/text must be strings");
        return nullptr;
    }
    auto vec = g_embedding->doc_embedding(title, text);
    if (vec == nullptr) {
        napi_throw_error(env, nullptr, "doc_embedding failed");
        return nullptr;
    }
    auto* data = vec->readMap<float>();
    auto size = vec->getInfo()->size;
    if (size > EMBED_DIM) {
        size = EMBED_DIM;
    }
    napi_value out = nullptr;
    void* buffer = nullptr;
    napi_create_arraybuffer(env, size * sizeof(float), &buffer, &out);
    memcpy(buffer, data, size * sizeof(float));
    napi_value typed = nullptr;
    napi_create_typedarray(env, napi_float32_array, size, out, 0, &typed);
    return typed;
}

EXTERN_C_START
static napi_value InitModule(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "initVisual", nullptr, InitVisual, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "embed", nullptr, Embed, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "embedDoc", nullptr, EmbedDoc, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "imgEmbed", nullptr, ImgEmbed, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isLoaded", nullptr, IsLoaded, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "prepareDir", nullptr, PrepareDir, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = InitModule,
    .nm_modname = "entry",
    .nm_priv = ((void*)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
