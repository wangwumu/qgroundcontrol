# ============================================================================
# Auth Module — 用户会话（登录 / 交接班 / 屏幕锁定）
# QML 单例 AuthController 编译进 main target（qmltyperegistrar 自动注册，
# 供 QML `import QGroundControl` 访问）。QML 文件在 src/CMakeLists.txt 的
# qt_add_qml_module 中登记。
# ============================================================================

target_sources(
    ${CMAKE_PROJECT_NAME}
    PRIVATE AuthController.cc
            AuthController.h
)

target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
