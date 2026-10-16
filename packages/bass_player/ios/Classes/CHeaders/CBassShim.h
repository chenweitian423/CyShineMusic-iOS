/*
 * 把 BASS 及本插件用到的附加库头文件聚合成一个 module，供 Swift `import CBass`。
 *
 * BASS 的 iOS xcframework 里只有二进制、不含 Headers，因此头文件由
 * tool/fetch_bass_ios.sh 从官方 zip 根目录取出来放到本目录，再由
 * module.modulemap 聚合成模块。
 */

#ifndef CYSHINE_CBASS_SHIM_H
#define CYSHINE_CBASS_SHIM_H

#include "bass.h"
#include "bassflac.h"
#include "bassape.h"
#include "bassopus.h"
#include "basswv.h"
#include "bassdsd.h"

#endif /* CYSHINE_CBASS_SHIM_H */
