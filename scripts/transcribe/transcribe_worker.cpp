
#include "transcribe.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <limits>
#include <locale>
#include <memory>
#include <mutex>
#include <optional>
#include <poll.h>
#include <signal.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {
constexpr uint32_t kMaximumSeconds = 30;
constexpr size_t kMaximumTextBytes = 1024 * 1024;
constexpr size_t kMaximumWords = 20000;
using Clock = std::chrono::steady_clock;

// Protocol output survives redirecting descriptor 1, including SDK printf output.
int protocolFD = -1;
void emit(const std::string &json) {
    const std::string line = json + "\n";
    size_t offset = 0;
    while (offset < line.size()) {
        const ssize_t n = ::write(protocolFD, line.data() + offset, line.size() - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) throw std::runtime_error("protocol_output_failed");
        offset += static_cast<size_t>(n);
    }
}

bool validUTF8(const std::string &s) {
    size_t i = 0;
    while (i < s.size()) {
        const auto first = static_cast<uint8_t>(s[i++]);
        if (first < 0x80) continue;
        int remaining;
        uint32_t value;
        uint32_t minimum;
        if (first >= 0xC2 && first <= 0xDF) { remaining = 1; value = first & 0x1F; minimum = 0x80; }
        else if (first >= 0xE0 && first <= 0xEF) { remaining = 2; value = first & 0x0F; minimum = 0x800; }
        else if (first >= 0xF0 && first <= 0xF4) { remaining = 3; value = first & 0x07; minimum = 0x10000; }
        else return false;
        if (s.size() - i < static_cast<size_t>(remaining)) return false;
        while (remaining--) {
            const auto next = static_cast<uint8_t>(s[i++]);
            if ((next & 0xC0) != 0x80) return false;
            value = (value << 6) | (next & 0x3F);
        }
        if (value < minimum || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) return false;
    }
    return true;
}

std::string jsonQuoted(const std::string &s) {
    if (!validUTF8(s)) throw std::runtime_error("sdk_invalid_utf8");
    static constexpr char hex[] = "0123456789abcdef";
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += static_cast<char>(c); }
        else if (c < 0x20) { out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15]; }
        else out += static_cast<char>(c);
    }
    return out + '"';
}

std::string boundedString(const char *value) {
    if (!value) return "";
    const size_t size = strnlen(value, kMaximumTextBytes + 1);
    if (size > kMaximumTextBytes) throw std::runtime_error("sdk_text_too_large");
    return std::string(value, size);
}

template <typename T> T little(const uint8_t *p) {
    T value = 0;
    for (size_t i = 0; i < sizeof(T); ++i) value |= static_cast<T>(p[i]) << (i * 8);
    return value;
}

struct Frame {
    uint64_t id;
    uint32_t rate;
    std::vector<float> samples;
};
struct Inbox {
    std::atomic<bool> stop{false};
    std::mutex lock;
    std::condition_variable changed;
    std::optional<Frame> pending; // At most one additional complete request.
    int exitCode = 0;
    std::string reason;

    void close(int code, const std::string &why) {
        std::lock_guard<std::mutex> guard(lock);
        if (!stop.load()) {
            exitCode = code;
            reason = why;
            pending.reset();
            stop.store(true);
        }
        changed.notify_all();
    }
};

enum class ReadResult { complete, eof, cancelled };
ReadResult readExact(Inbox &inbox, void *bytes, size_t size) {
    size_t have = 0;
    auto *destination = static_cast<uint8_t *>(bytes);
    while (have < size) {
        if (inbox.stop.load()) return ReadResult::cancelled;
        pollfd fd{STDIN_FILENO, POLLIN, 0};
        const int pollResult = ::poll(&fd, 1, 100);
        if (pollResult < 0 && errno == EINTR) continue;
        if (pollResult < 0 || (fd.revents & (POLLERR | POLLNVAL))) throw std::runtime_error("stdin_read_failed");
        if (pollResult == 0) continue;
        // POLLHUP may coexist with readable buffered data; drain it before EOF.
        const ssize_t n = ::read(STDIN_FILENO, destination + have, size - have);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) throw std::runtime_error("stdin_read_failed");
        if (n == 0) {
            if (have != 0) throw std::runtime_error("truncated_frame");
            return ReadResult::eof;
        }
        have += static_cast<size_t>(n);
    }
    return ReadResult::complete;
}

void receive(Inbox &inbox) {
    uint64_t lastID = 0;
    try {
        while (!inbox.stop.load()) {
            std::array<uint8_t, 20> header{};
            const auto status = readExact(inbox, header.data(), header.size());
            if (status == ReadResult::cancelled) return;
            if (status == ReadResult::eof) { inbox.close(0, "stdin_eof"); return; }
            if (std::memcmp(header.data(), "ORK1", 4) != 0) throw std::runtime_error("invalid_magic");
            Frame frame{little<uint64_t>(header.data() + 4), little<uint32_t>(header.data() + 12), {}};
            const uint32_t count = little<uint32_t>(header.data() + 16);
            if (frame.id == 0 || frame.id <= lastID) throw std::runtime_error("request_id_not_increasing");
            if (frame.rate < 8000 || frame.rate > 96000 || count == 0 ||
                count > static_cast<uint64_t>(frame.rate) * kMaximumSeconds) throw std::runtime_error("invalid_audio_bounds");
            frame.samples.resize(count);
            const auto payload = readExact(inbox, frame.samples.data(), static_cast<size_t>(count) * 4);
            if (payload == ReadResult::cancelled) return;
            if (payload != ReadResult::complete) throw std::runtime_error("truncated_audio");
            // Decode explicitly, without depending on host endianness or pointer aliasing.
            for (float &sample : frame.samples) {
                std::array<uint8_t, 4> bytes{};
                std::memcpy(bytes.data(), &sample, 4);
                const uint32_t bits = little<uint32_t>(bytes.data());
                std::memcpy(&sample, &bits, 4);
                if (!std::isfinite(sample)) throw std::runtime_error("nonfinite_audio");
            }
            lastID = frame.id;
            {
                std::lock_guard<std::mutex> guard(inbox.lock);
                if (inbox.stop.load()) return;
                if (inbox.pending) throw std::runtime_error("request_queue_full");
                inbox.pending = std::move(frame);
            }
            inbox.changed.notify_one();
        }
    } catch (const std::exception &error) { inbox.close(65, error.what()); }
    catch (...) { inbox.close(70, "stdin_reader_failed"); }
}


std::string resultJSON(const Frame &frame, transcribe_session *session, double elapsedMS) {
    const auto kind = transcribe_returned_timestamp_kind(session);
    const int count = kind == TRANSCRIBE_TIMESTAMPS_WORD || kind == TRANSCRIBE_TIMESTAMPS_TOKEN
        ? transcribe_n_words(session) : 0;
    if (count < 0 || static_cast<size_t>(count) > kMaximumWords) throw std::runtime_error("sdk_too_many_words");
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::setprecision(12) << "{\"type\":\"result\",\"request_id\":" << jsonQuoted(std::to_string(frame.id))
        << ",\"mode\":\"offline\",\"is_final\":true"
        << ",\"sample_rate\":" << frame.rate << ",\"sample_count\":" << frame.samples.size()
        << ",\"recognition_ms\":" << elapsedMS
        << ",\"timestamps\":" << jsonQuoted(count > 0 ? "word" : (kind == TRANSCRIBE_TIMESTAMPS_SEGMENT ? "segment" : "none"))
        << ",\"text\":" << jsonQuoted(boundedString(transcribe_full_text(session)))
        << ",\"words\":[";
    for (int i = 0; i < count; ++i) {
        transcribe_word word;
        transcribe_word_init(&word);
        if (transcribe_get_word(session, i, &word) != TRANSCRIBE_OK) throw std::runtime_error("sdk_word_failed");
        if (i) out << ',';
        out << "{\"text\":" << jsonQuoted(boundedString(word.text))
            << ",\"start_ms\":" << word.t0_ms << ",\"end_ms\":" << word.t1_ms << '}';
        if (out.tellp() > static_cast<std::streamoff>(4 * kMaximumTextBytes)) throw std::runtime_error("sdk_result_too_large");
    }
    out << "]}";
    return out.str();
}

struct Session {
    transcribe_session *value = nullptr;
    ~Session() { if (value) transcribe_close(value); } // frees the owned model too (Metal needs it)
};

int run(int argc, char **argv) {
    static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559, "IEEE754 Float32 required");
    if (argc != 5 || std::strcmp(argv[1], "--model") != 0 || std::strcmp(argv[3], "--gpu") != 0 ||
        (std::strcmp(argv[4], "0") != 0 && std::strcmp(argv[4], "-1") != 0)) {
        emit("{\"type\":\"error\",\"code\":\"usage\",\"message\":\"Expected --model /absolute/model.gguf --gpu 0|-1\"}");
        return 64;
    }
    struct stat modelStat{};
    if (argv[2][0] != '/' || ::stat(argv[2], &modelStat) != 0 || !S_ISREG(modelStat.st_mode) ||
        modelStat.st_size <= 0 || ::access(argv[2], R_OK) != 0) {
        emit("{\"type\":\"error\",\"code\":\"invalid_model_path\"}");
        return 66;
    }
    const bool gpu = std::strcmp(argv[4], "0") == 0;
    transcribe_model_load_params load;
    transcribe_model_load_params_init(&load);
    load.backend = gpu ? TRANSCRIBE_BACKEND_METAL : TRANSCRIBE_BACKEND_CPU;
    Session session;
    const auto began = Clock::now();
    auto status = transcribe_open(argv[2], &load, nullptr, &session.value);
    if (status == TRANSCRIBE_ERR_BACKEND && gpu) { // documented recovery: reload on CPU
        load.backend = TRANSCRIBE_BACKEND_CPU;
        status = transcribe_open(argv[2], &load, nullptr, &session.value);
    }
    if (status != TRANSCRIBE_OK || !session.value) {
        emit("{\"type\":\"error\",\"code\":\"model_load_failed\",\"sdk_status\":" + std::to_string(static_cast<int>(status)) +
             ",\"message\":" + jsonQuoted(boundedString(transcribe_status_string(status))) + "}");
        return 70;
    }
    transcribe_run_params params;
    transcribe_run_params_init(&params); // AUTO timestamps: the richest the model supports
    {
        // Metal pre-warm on a short silence, so the first real request is not the cold one.
        std::vector<float> silence(16000, 0.0f);
        (void)transcribe_run(session.value, silence.data(), static_cast<int>(silence.size()), &params);
    }
    const double loadMS = std::chrono::duration<double, std::milli>(Clock::now() - began).count();
    emit("{\"type\":\"ready\",\"protocol\":\"ORK1\",\"mode\":\"offline_retained\",\"sample_format\":\"mono_f32le\","
         "\"max_seconds\":30,\"backend_requested\":" + jsonQuoted(gpu ? "metal" : "cpu") +
         ",\"backend_verified\":false,\"sdk_version\":" + jsonQuoted(std::string("transcribe.cpp ") + boundedString(transcribe_version())) +
         ",\"load_ms\":" + std::to_string(loadMS) + "}");

    Inbox inbox;
    std::thread reader([&] { receive(inbox); });
    try {
        while (!inbox.stop.load()) {
            std::optional<Frame> frame;
            {
                std::unique_lock<std::mutex> guard(inbox.lock);
                inbox.changed.wait(guard, [&] { return inbox.stop.load() || inbox.pending.has_value(); });
                if (inbox.stop.load()) break;
                frame = std::move(inbox.pending);
                inbox.pending.reset();
            }
            const std::string requestID = std::to_string(frame->id);
            if (frame->rate != 16000) {
                emit("{\"type\":\"error\",\"request_id\":" + jsonQuoted(requestID) + ",\"code\":\"unsupported_sample_rate\"}");
                inbox.close(65, "unsupported_sample_rate");
                break;
            }
            const auto started = Clock::now();
            const auto runStatus = transcribe_run(session.value, frame->samples.data(),
                                                  static_cast<int>(frame->samples.size()), &params);
            // EOF is cancellation, not an end-of-utterance request. Never publish a late result.
            if (inbox.stop.load()) break;
            if (runStatus != TRANSCRIBE_OK) {
                emit("{\"type\":\"error\",\"request_id\":" + jsonQuoted(requestID) +
                     ",\"code\":\"recognition_failed\",\"sdk_status\":" + std::to_string(static_cast<int>(runStatus)) +
                     ",\"message\":" + jsonQuoted(boundedString(transcribe_status_string(runStatus))) + "}");
                inbox.close(70, "recognition_failed");
                break;
            }
            const auto json = resultJSON(*frame, session.value, std::chrono::duration<double, std::milli>(Clock::now() - started).count());
            if (!inbox.stop.load()) emit(json);
        }
    } catch (const std::exception &error) { inbox.close(70, error.what()); }
    catch (...) { inbox.close(70, "worker_failed"); }
    reader.join();
    if (inbox.exitCode != 0) emit("{\"type\":\"error\",\"code\":" + jsonQuoted(inbox.reason) + "}");
    else emit("{\"type\":\"closed\",\"reason\":\"stdin_eof\"}");
    return inbox.exitCode;
}
} // namespace

int main(int argc, char **argv) {
    ::signal(SIGPIPE, SIG_IGN);
    protocolFD = ::dup(STDOUT_FILENO);
    if (protocolFD < 0 || ::fcntl(protocolFD, F_SETFD, FD_CLOEXEC) < 0 || ::dup2(STDERR_FILENO, STDOUT_FILENO) < 0) return 74;
    // Flush stdout SDK diagnostics promptly to stderr; protocol uses only protocolFD.
    ::setvbuf(stdout, nullptr, _IONBF, 0);
    int code = 70;
    try { code = run(argc, argv); }
    catch (const std::exception &error) {
        try { emit("{\"type\":\"error\",\"code\":" + jsonQuoted(error.what()) + "}"); } catch (...) {}
    } catch (...) {
        try { emit("{\"type\":\"error\",\"code\":\"worker_failed\"}"); } catch (...) {}
    }
    ::close(protocolFD);
    return code;
}
