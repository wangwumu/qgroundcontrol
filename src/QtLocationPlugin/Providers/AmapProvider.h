#pragma once

#include <QtCore/QObject>

#include "MapProvider.h"

static constexpr const quint32 AVERAGE_AMAP_STREET_MAP = 12927;
static constexpr const quint32 AVERAGE_AMAP_SAT_MAP    = 29613;
// 2026-10-03 量的是**合成后**的瓦片（影像 + 路网注记，JPEG q90，z=13 同一取样点 36126 B）。
// 旧值 44302 量错对象 —— 那是 style=8 叠加层单张的大小，而叠加层 84% 像素是透明的。
static constexpr const quint32 AVERAGE_AMAP_HYBRID_MAP = 36126;

/// 高德地图（amap.com）瓦片。
///
/// ‼️ 与其它所有 provider 的关键差别：**高德瓦片是 GCJ-02（火星坐标）**
/// —— 按国家测绘法，国内公开地图服务必须对 WGS-84 施加非线性偏移后再出图。
/// 而 QGC 里其它一切都是 WGS-84（MAVLink 遥测、航点、站点、机位、瓦片网格索引），
/// 所以底图与图标之间会有一层**系统性错位**，与代码正确性无关、改代码也消不掉。
///
/// 实测（2026-10-02，本机，手法＝同一 z/x/y 上高德影像与 Bing 影像做零均值归一化
/// 互相关，取峰值位移换算成地面米数）：
///
///   地点            缩放    位移
///   天津机场         z=13    576 m
///   天津机场         z=14    578 m   ← 换缩放后地面距离不变 ⇒ 是固定地面平移
///   北京国贸         z=13    534 m
///   上海人民广场     z=13    483 m
///   深圳市民中心     z=13    602 m
///
/// 天津（本项目站点所在）的具体向量：底图地物相对 WGS-84 网格**偏东 563 m、偏北 119 m**。
/// 后果＝按 WGS-84 画出来的无人机箭头、航线、机位图标，会压在它真实位置**西南方约 576 m**
/// 的地物上。精度要求到机位测绘那一级（站点网格步长 0.000225°≈25 m）时不可接受。
///
/// ⇒ 只在"看图快、不要准"的场合用。既要国内速度又要 WGS-84，走 `TianDiTuProvider`
/// （天地图是国家测绘局的 WGS-84 服务，代码已在本目录，只差一个免费 token）。
class AmapProvider : public MapProvider
{
protected:
    AmapProvider(const QString &mapName, const QString &host, const QString &query, const QString &imageFormat,
                 quint32 averageSize, MapProvider::MapStyle mapStyle, const QString &overlayQuery = QString())
        : MapProvider(mapName, QStringLiteral("https://www.amap.com/"), imageFormat, averageSize, mapStyle)
        , _host(host)
        , _query(query)
        , _overlayQuery(overlayQuery) {}

private:
    QString _getURL(int x, int y, int zoom) const final;
    QString _getOverlayURL(int x, int y, int zoom) const final;
    QString _buildUrl(int x, int y, int zoom, const QString &query) const;

    const QString _host;
    const QString _query;
    const QString _overlayQuery;  // 非空 ⇒ 该档是双层（底图 + 透明叠加层），由 QGeoTiledMapReplyQGC 合成
    // %1 主机前缀, %2 服务器编号(01-04), %3 查询串, %4/%5/%6 = x/y/z
    const QString _mapUrl = QStringLiteral("https://%1%2.is.autonavi.com/appmaptile?%3x=%4&y=%5&z=%6");
};

class AmapRoadProvider : public AmapProvider
{
public:
    AmapRoadProvider()
        : AmapProvider(
            QObject::tr("Amap Road"),
            QStringLiteral("webrd"),
            QStringLiteral("lang=zh_cn&size=1&scale=1&style=8&"),
            QStringLiteral("png"),
            AVERAGE_AMAP_STREET_MAP,
            MapProvider::StreetMap) {}
};

class AmapSatelliteProvider : public AmapProvider
{
public:
    AmapSatelliteProvider()
        : AmapProvider(
            QObject::tr("Amap Satellite"),
            QStringLiteral("webst"),
            QStringLiteral("style=6&"),
            QStringLiteral("jpg"),
            AVERAGE_AMAP_SAT_MAP,
            MapProvider::SatelliteMapDay) {}
};

/// 影像 + 路网 + 注记，对应 `Bing Hybrid` 那一档。
///
/// ‼️ 高德**没有**单张就带路网的影像瓦片，所以这一档必须**叠两层**：
///
///   底图   `style=6`  不透明卫星影像（本档唯一的影像源）
///   叠加层 `style=8`  带 alpha 的路网 + 注记，84% 像素透明
///
/// 实测（2026-10-03，本机，z=15 天津机场）：把 style 1–12 × ltype 0–15 全扫一遍，
/// **只有 style=6 返回不透明影像**；其余 style 全是矢量图或透明叠加层，`ltype` 对 style=6 完全无影响。
/// ⇒ 单 URL 拿不到「卫星+路网」，只能由 `QGeoTiledMapReplyQGC` 客户端合成。
///
/// ⚠️ 在合成落地之前，本档写的是 `style=8` 单层 —— 那是**一张 84% 透明的叠加层**，
/// 在 QGC 里渲染出来就是「空白底 + 几条路 + 几个地名」，并不是卫星图。本次一并修掉。
///
/// ‼️ 高德真实数据止于 **z=18**，再往上服务端只回占位图（都伪装成合法图片）：
/// z=19/20 底图是 4235 B 的「此区域无卫星图」占位图，z≥21 叠加层还 302 到 `empty.png`
/// ——一张**全不透明**的纯色图。后者若不拦会把整块瓦片涂成纯色，见 `QGeoMapReplyQGC.cpp`
/// 里的 `_hasTransparentPixel`。判据＝按 RGBA 解出来数 alpha，肉眼看 png 会看错（透明被画成白）。
class AmapHybridProvider : public AmapProvider
{
public:
    AmapHybridProvider()
        : AmapProvider(
            QObject::tr("Amap Hybrid"),
            QStringLiteral("webst"),
            QStringLiteral("style=6&"),
            QStringLiteral("jpg"),
            AVERAGE_AMAP_HYBRID_MAP,
            MapProvider::HybridMap,
            QStringLiteral("style=8&")) {}
};
