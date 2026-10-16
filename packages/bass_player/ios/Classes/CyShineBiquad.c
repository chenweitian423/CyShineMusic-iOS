#include "CyShineBiquad.h"

#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

typedef struct {
    double b0, b1, b2, a1, a2;
    /* 每声道两级直接 II 型状态。iOS 输出最多 2 声道，留 2 个够用。 */
    double z1[2];
    double z2[2];
} CyShineBiquad;

typedef struct {
    int type;
    double frequencyHz;
    double gainDb;
    double q;
} CyShineBiquadSpec;

struct CyShineBiquadChain {
    double sampleRate;

    double inputGain;  /* 线性 */
    double outputGain; /* 线性 */
    int bandCount;
    CyShineBiquad bands[CYSHINE_MAX_BIQUAD_BANDS];

    /* 暂存区：configure 写入，process 消费。 */
    pthread_mutex_t lock;
    int hasPending;
    double pendingInputGain;
    double pendingOutputGain;
    int pendingCount;
    CyShineBiquadSpec pending[CYSHINE_MAX_BIQUAD_BANDS];
};

static double db_to_linear(double db) { return pow(10.0, db / 20.0); }

/* RBJ Audio EQ Cookbook。返回 0 表示该段参数非法（静默跳过而不是中断整条链）。 */
static int compute_coefficients(const CyShineBiquadSpec *spec,
                                double sampleRate,
                                CyShineBiquad *out) {
    if (sampleRate <= 0.0) return 0;
    if (!(spec->frequencyHz > 0.0)) return 0;

    /* 频率必须落在 (0, Nyquist) 内，越界会让 tan/alpha 失去意义。 */
    double nyquist = sampleRate * 0.5;
    double f0 = spec->frequencyHz;
    if (f0 >= nyquist) f0 = nyquist * 0.9999;
    if (f0 <= 0.0) f0 = 1.0;

    double q = spec->q;
    if (!(q > 0.0)) q = 0.707;
    if (q > 100.0) q = 100.0;

    double w0 = 2.0 * M_PI * f0 / sampleRate;
    double cosw0 = cos(w0);
    double sinw0 = sin(w0);

    double b0, b1, b2, a0, a1, a2;

    switch (spec->type) {
        case CYSHINE_FILTER_LOW_PASS: {
            double alpha = sinw0 / (2.0 * q);
            b0 = (1.0 - cosw0) * 0.5;
            b1 = 1.0 - cosw0;
            b2 = (1.0 - cosw0) * 0.5;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosw0;
            a2 = 1.0 - alpha;
            break;
        }
        case CYSHINE_FILTER_HIGH_PASS: {
            double alpha = sinw0 / (2.0 * q);
            b0 = (1.0 + cosw0) * 0.5;
            b1 = -(1.0 + cosw0);
            b2 = (1.0 + cosw0) * 0.5;
            a0 = 1.0 + alpha;
            a1 = -2.0 * cosw0;
            a2 = 1.0 - alpha;
            break;
        }
        case CYSHINE_FILTER_LOW_SHELF: {
            double A = pow(10.0, spec->gainDb / 40.0);
            double sqrtA = sqrt(A);
            /* BASS_FX 的 shelf 用 Q 作为斜率 S；保持一致。 */
            double S = q;
            double alpha = sinw0 * 0.5 * sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
            b0 = A * ((A + 1.0) - (A - 1.0) * cosw0 + 2.0 * sqrtA * alpha);
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw0);
            b2 = A * ((A + 1.0) - (A - 1.0) * cosw0 - 2.0 * sqrtA * alpha);
            a0 = (A + 1.0) + (A - 1.0) * cosw0 + 2.0 * sqrtA * alpha;
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosw0);
            a2 = (A + 1.0) + (A - 1.0) * cosw0 - 2.0 * sqrtA * alpha;
            break;
        }
        case CYSHINE_FILTER_HIGH_SHELF: {
            double A = pow(10.0, spec->gainDb / 40.0);
            double sqrtA = sqrt(A);
            double S = q;
            double alpha = sinw0 * 0.5 * sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
            b0 = A * ((A + 1.0) + (A - 1.0) * cosw0 + 2.0 * sqrtA * alpha);
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw0);
            b2 = A * ((A + 1.0) + (A - 1.0) * cosw0 - 2.0 * sqrtA * alpha);
            a0 = (A + 1.0) - (A - 1.0) * cosw0 + 2.0 * sqrtA * alpha;
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosw0);
            a2 = (A + 1.0) - (A - 1.0) * cosw0 - 2.0 * sqrtA * alpha;
            break;
        }
        case CYSHINE_FILTER_PEAKING:
        default: {
            double A = pow(10.0, spec->gainDb / 40.0);
            double alpha = sinw0 / (2.0 * q);
            b0 = 1.0 + alpha * A;
            b1 = -2.0 * cosw0;
            b2 = 1.0 - alpha * A;
            a0 = 1.0 + alpha / A;
            a1 = -2.0 * cosw0;
            a2 = 1.0 - alpha / A;
            break;
        }
    }

    if (!isfinite(a0) || fabs(a0) < 1e-12) return 0;

    out->b0 = b0 / a0;
    out->b1 = b1 / a0;
    out->b2 = b2 / a0;
    out->a1 = a1 / a0;
    out->a2 = a2 / a0;
    return 1;
}

static void reset_state(CyShineBiquad *band) {
    band->z1[0] = band->z1[1] = 0.0;
    band->z2[0] = band->z2[1] = 0.0;
}

CyShineBiquadChain *cyshine_biquad_chain_create(double sampleRate) {
    CyShineBiquadChain *chain = calloc(1, sizeof(CyShineBiquadChain));
    if (chain == NULL) return NULL;
    chain->sampleRate = (sampleRate > 0.0) ? sampleRate : 44100.0;
    chain->inputGain = 1.0;
    chain->outputGain = 1.0;
    chain->bandCount = 0;
    pthread_mutex_init(&chain->lock, NULL);
    return chain;
}

void cyshine_biquad_chain_destroy(CyShineBiquadChain *chain) {
    if (chain == NULL) return;
    pthread_mutex_destroy(&chain->lock);
    free(chain);
}

void cyshine_biquad_chain_configure(CyShineBiquadChain *chain,
                                    double inputGainDb,
                                    double outputGainDb,
                                    const CyShineBiquadBand *bands,
                                    int bandCount) {
    if (chain == NULL) return;
    if (bandCount < 0) bandCount = 0;
    if (bandCount > CYSHINE_MAX_BIQUAD_BANDS) bandCount = CYSHINE_MAX_BIQUAD_BANDS;

    pthread_mutex_lock(&chain->lock);
    chain->pendingInputGain = db_to_linear(inputGainDb);
    chain->pendingOutputGain = db_to_linear(outputGainDb);
    chain->pendingCount = bandCount;
    for (int i = 0; i < bandCount; i++) {
        chain->pending[i].type = bands[i].type;
        chain->pending[i].frequencyHz = bands[i].frequencyHz;
        chain->pending[i].gainDb = bands[i].gainDb;
        chain->pending[i].q = bands[i].q;
    }
    chain->hasPending = 1;
    pthread_mutex_unlock(&chain->lock);
}

void cyshine_biquad_chain_reset(CyShineBiquadChain *chain) {
    if (chain == NULL) return;
    pthread_mutex_lock(&chain->lock);
    for (int i = 0; i < chain->bandCount; i++) reset_state(&chain->bands[i]);
    pthread_mutex_unlock(&chain->lock);
}

/* 只在音频线程调用。 */
static void apply_pending(CyShineBiquadChain *chain) {
    int applied = 0;
    pthread_mutex_lock(&chain->lock);
    if (chain->hasPending) {
        chain->inputGain = chain->pendingInputGain;
        chain->outputGain = chain->pendingOutputGain;
        int count = 0;
        for (int i = 0; i < chain->pendingCount; i++) {
            CyShineBiquad candidate;
            memset(&candidate, 0, sizeof(candidate));
            if (!compute_coefficients(&chain->pending[i], chain->sampleRate, &candidate)) {
                continue;
            }
            chain->bands[count] = candidate;
            count++;
        }
        chain->bandCount = count;
        chain->hasPending = 0;
        applied = 1;
    }
    pthread_mutex_unlock(&chain->lock);
    (void)applied;
}

void cyshine_biquad_chain_process(CyShineBiquadChain *chain,
                                  float *buffer,
                                  unsigned long frames,
                                  unsigned int channels) {
    if (chain == NULL || buffer == NULL || frames == 0 || channels == 0) return;

    apply_pending(chain);

    if (channels > 2) channels = 2;
    const int hasGain =
        fabs(chain->inputGain - 1.0) > 1e-9 || fabs(chain->outputGain - 1.0) > 1e-9;
    if (chain->bandCount == 0 && !hasGain) return;

    for (unsigned long frame = 0; frame < frames; frame++) {
        for (unsigned int ch = 0; ch < channels; ch++) {
            unsigned long index = frame * channels + ch;
            double sample = (double)buffer[index] * chain->inputGain;

            for (int b = 0; b < chain->bandCount; b++) {
                CyShineBiquad *band = &chain->bands[b];
                /* 转置直接 II 型。 */
                double out = band->b0 * sample + band->z1[ch];
                band->z1[ch] = band->b1 * sample - band->a1 * out + band->z2[ch];
                band->z2[ch] = band->b2 * sample - band->a2 * out;
                sample = out;
            }

            sample *= chain->outputGain;

            /* 浮点溢出保护：极端 EQ 设置下仍要留在 [-1,1] 之外不至于产生 NaN。 */
            if (!isfinite(sample)) sample = 0.0;
            if (sample > 4.0) sample = 4.0;
            if (sample < -4.0) sample = -4.0;

            buffer[index] = (float)sample;
        }
    }
}
