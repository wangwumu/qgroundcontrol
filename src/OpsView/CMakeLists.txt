# ============================================================================
# Ops View Module
# 飞行监控主界面（站点操作员 SITE_ATC / 航线监控员 ROUTE_MONITOR）
# 站点操作员视图设计见 docs/qgc/飞行监控主界面设计.md
# 航线监控员视图（RomView + RouteListPanel）设计见 docs/qgc/航线监控员主界面设计-20260922.md
# ============================================================================

qt_add_library(OpsViewModule STATIC)

qt_add_qml_module(OpsViewModule
    URI QGroundControl.OpsView
    VERSION 1.0
    RESOURCE_PREFIX /qml
    QML_FILES
        OpsShell.qml
        OpsView.qml
        RomView.qml
        RouteListPanel.qml
        SlotLayout.qml
        TaskListPanel.qml
        OpsCommon.js
    NO_PLUGIN
)
