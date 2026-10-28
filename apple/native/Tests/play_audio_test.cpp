#include "ui_libretro/SH_LibreAudio.h"
#include "ui_libretro/ext/libretro.h"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

static std::vector<int16_t> received;
static size_t limit = 100000;
static size_t consume(const int16_t* samples, size_t frames)
{
    frames = std::min(frames, limit);
    received.insert(received.end(), samples, samples + frames * 2);
    return frames;
}
retro_audio_sample_batch_t g_set_audio_sample_batch_cb = consume;

int main()
{
    CSH_LibreAudio sound;
    int16_t first[] = {1, -1, 2, -2};
    int16_t second[] = {3, -3, 4, -4, 5, -5};
    sound.Write(first, 4, 44100);
    sound.Write(second, 6, 44100);
    sound.ProcessBuffer();
    assert((received == std::vector<int16_t>{1,-1,2,-2,3,-3,4,-4,5,-5}));
    sound.ProcessBuffer();
    assert(received.size() == 10); // No replay of already consumed samples.

    received.clear(); limit = 1;
    sound.Write(first, 4, 44100);
    sound.ProcessBuffer();
    sound.Write(second, 6, 44100);
    limit = 100000; sound.ProcessBuffer();
    assert((received == std::vector<int16_t>{1,-1,2,-2,3,-3,4,-4,5,-5}));

    received.clear();
    sound.Write(first, 4, 44100); sound.Reset(); sound.ProcessBuffer();
    assert(received.empty());
    // Multiple SPU writes per video frame must retain a full second of stereo.
    std::vector<int16_t> block(90, 17);
    for (int i = 0; i < 980; ++i) sound.Write(block.data(), 90, 44100);
    sound.ProcessBuffer();
    assert(received.size() == 44100 * 2);
    assert(std::all_of(received.begin(), received.end(), [](int16_t s){return s == 17;}));
    received.clear();
    std::atomic<bool> done{false};
    std::thread producer([&]{
        for (int i = 0; i < 10000; ++i) {
            int16_t pair[] = {static_cast<int16_t>(i), static_cast<int16_t>(-i)};
            sound.Write(pair, 2, 44100);
        }
        done.store(true, std::memory_order_release);
    });
    while (!done.load(std::memory_order_acquire)) sound.ProcessBuffer();
    producer.join(); sound.ProcessBuffer();
    assert(received.size() == 20000);
    for (int i = 0; i < 10000; ++i) {
        assert(received[i*2] == i && received[i*2+1] == -i);
    }
    std::cout << "PASS: SPU batches, stereo counts, partial consumption, reset and concurrent delivery\n";
}
