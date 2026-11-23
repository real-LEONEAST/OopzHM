cmake_minimum_required(VERSION 3.16)
project(oopz_voip_trial LANGUAGES CXX)

set(AGORA "${CMAKE_CURRENT_SOURCE_DIR}/../../../oh_modules/@shengwang/rtc-voice")
add_library(oopz_voip_trial SHARED voip_trial.cpp)
target_compile_features(oopz_voip_trial PRIVATE cxx_std_17)
target_include_directories(oopz_voip_trial PRIVATE "${AGORA}/include")
target_link_libraries(oopz_voip_trial PRIVATE
    "${AGORA}/libs/${OHOS_ARCH}/libagora_rtc_sdk.so"
    libace_napi.z.so)
