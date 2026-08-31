# ============================================================================
# Ops View Module
# 飞行监控主界面（站点操作员 SITE_ATC / 航线监控员 ROUTE_MONITOR）
# 设计见 docs/qgc/飞行监控主界面设计.md
# ============================================================================

qt_add_library(OpsViewModule STATIC)

qt_add_qml_module(OpsViewModule
    URI QGroundControl.OpsView
    VERSION 1.0
    RESOURCE_PREFIX /qml
    QML_FILES
        OpsView.qml
    NO_PLUGIN
)
