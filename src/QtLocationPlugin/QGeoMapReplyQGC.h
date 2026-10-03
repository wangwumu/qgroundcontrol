#pragma once

#include <QtLocation/private/qgeotiledmapreply_p.h>
#include <QtNetwork/QNetworkReply>
#include <QtNetwork/QNetworkRequest>

#include "QGCMapTaskBase.h"

struct QGCCacheTile;
class QNetworkAccessManager;
class QSslError;

class QGeoTiledMapReplyQGC : public QGeoTiledMapReply
{
    Q_OBJECT

public:
    explicit QGeoTiledMapReplyQGC(QNetworkAccessManager *networkManager, const QNetworkRequest &request, const QGeoTileSpec &spec, QObject *parent = nullptr);
    ~QGeoTiledMapReplyQGC();

    bool init();
    void abort() final;

private slots:
    void _networkReplyFinished();
    void _networkReplyError(QNetworkReply::NetworkError error);
    void _networkReplySslErrors(const QList<QSslError> &errors);
    void _overlayReplyFinished();
    void _cacheReply(QGCCacheTile *tile);
    void _cacheError(QGCMapTask::TaskType type, QStringView errorString);

private:
    static void _initDataFromResources();

    /// 落盘 + 收尾：设置图像数据/格式、写瓦片缓存、setFinished。
    /// 单层 provider 直接调它；双层 provider 等叠加层合完再调。
    void _finalizeTile(const QByteArray &image);

    QNetworkAccessManager *_networkManager = nullptr;
    QNetworkRequest _request;
    bool m_initialized = false;

    // 双层 provider（见 MapProvider::_getOverlayURL）用：底图字节先存下来，
    // 等叠加层到齐后合成。_overlayUrl 为空即单层。
    QUrl _overlayUrl;
    QByteArray _baseImage;

    static QByteArray _bingNoTileImage;
    static QByteArray _badTile;
};
