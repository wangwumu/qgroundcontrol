# ============================================================================
# Crypto Module
# deviceID 重组 + AES-256-GCM payload 加密（加密 MAVLink 链路）
# ============================================================================

target_sources(
    ${CMAKE_PROJECT_NAME}
    PRIVATE CryptoCodec.cc
            CryptoCodec.h
            CryptoController.cc
            CryptoController.h
            DeviceID.h
            DeviceKeyManager.cc
            DeviceKeyManager.h
            MAVLinkCrypto.cc
            MAVLinkCrypto.h
            ReplayGuard.cc
            ReplayGuard.h
)

target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# ----------------------------------------------------------------------------
# OpenSSL (AES-256-GCM)
# ----------------------------------------------------------------------------
if(ANDROID)
    # Android：OpenSSL 库由 cmake/modules/AndroidOpenSSL.cmake 的
    # add_android_openssl_libraries(${CMAKE_PROJECT_NAME}) 统一链接
    # （libssl_3.so / libcrypto_3.so，含多 ABI 处理）。
    # 这里补充头文件搜索路径：add_android_openssl_libraries 若以 INTERFACE 传播
    # 头文件目录，对主 target 自身源文件的编译并不生效，故用 PRIVATE 显式补齐。
    if(DEFINED android_openssl_SOURCE_DIR)
        target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE "${android_openssl_SOURCE_DIR}/ssl_3/include")
    endif()
else()
    # 桌面平台使用系统 OpenSSL。
    # 直接链接 OPENSSL_CRYPTO_LIBRARY 文件路径（而非 imported target OpenSSL::Crypto），
    # 以避开 qt_generate_deploy_qml_app_script 对 imported target 的 TARGET_LINKER_FILE 展开。
    find_package(OpenSSL REQUIRED)
    target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE ${OPENSSL_INCLUDE_DIR})
    target_link_libraries(${CMAKE_PROJECT_NAME} PRIVATE ${OPENSSL_CRYPTO_LIBRARY})
endif()
