#include "QGeoMapReplyQGC.h"

#include <QtCore/QBuffer>
#include <QtCore/QFile>
#include <QtGui/QImage>
#include <QtGui/QPainter>
#include <QtLocation/private/qgeotilespec_p.h>
#include <QtNetwork/QNetworkAccessManager>
#include <QtNetwork/QSslError>

#include "ElevationMapProvider.h"
#include "MapProvider.h"
#include "QGCCacheTile.h"
#include "QGCLoggingCategory.h"
#include "QGCMapEngine.h"
#include "QGCMapTasks.h"
#include "QGCMapUrlEngine.h"
#include "QGCNetworkHelper.h"
#include "QGeoFileTileCacheQGC.h"

QGC_LOGGING_CATEGORY(QGeoTiledMapReplyQGCLog, "QtLocationPlugin.QGeoTiledMapReplyQGC")

namespace {

/// 叠加层的契约是「带 alpha 的透明瓦片」，所以只要有一个透明像素才算数。
/// 高德在影像覆盖范围外回的是**合法但不透明**的纯色占位图，直接叠上去会把底图整个盖掉。
bool _hasTransparentPixel(const QImage &image)
{
    const QImage argb = image.convertToFormat(QImage::Format_ARGB32);
    for (int y = 0; y < argb.height(); ++y) {
        const QRgb *line = reinterpret_cast<const QRgb *>(argb.constScanLine(y));
        for (int x = 0; x < argb.width(); ++x) {
            if (qAlpha(line[x]) < 255) {
                return true;
            }
        }
    }

    return false;
}

} // namespace

QByteArray QGeoTiledMapReplyQGC::_bingNoTileImage;
QByteArray QGeoTiledMapReplyQGC::_badTile;

QGeoTiledMapReplyQGC::QGeoTiledMapReplyQGC(QNetworkAccessManager *networkManager, const QNetworkRequest &request, const QGeoTileSpec &spec, QObject *parent)
    : QGeoTiledMapReply(spec, parent)
    , _networkManager(networkManager)
    , _request(request)
{
    qCDebug(QGeoTiledMapReplyQGCLog) << this;
}

QGeoTiledMapReplyQGC::~QGeoTiledMapReplyQGC()
{
    qCDebug(QGeoTiledMapReplyQGCLog) << this;
}

bool QGeoTiledMapReplyQGC::init()
{
    if (m_initialized) {
        return true;
    }

    m_initialized = true;

    _initDataFromResources();

    (void) connect(this, &QGeoTiledMapReplyQGC::errorOccurred, this, [this](QGeoTiledMapReply::Error error, const QString &errorString) {
        qCWarning(QGeoTiledMapReplyQGCLog) << error << errorString;
        setMapImageData(_badTile);
        setMapImageFormat(QStringLiteral("png"));
        setCached(false);
    }, Qt::AutoConnection);

    QGCFetchTileTask *task = QGeoFileTileCacheQGC::createFetchTileTask(UrlFactory::getProviderTypeFromQtMapId(tileSpec().mapId()), tileSpec().x(), tileSpec().y(), tileSpec().zoom());
    if (!task) {
        qCWarning(QGeoTiledMapReplyQGCLog) << "Failed to create fetch tile task";
        m_initialized = false;
        return false;
    }
    (void) connect(task, &QGCFetchTileTask::tileFetched, this, &QGeoTiledMapReplyQGC::_cacheReply);
    (void) connect(task, &QGCMapTask::error, this, &QGeoTiledMapReplyQGC::_cacheError);
    if (!getQGCMapEngine()->addTask(task)) {
        task->deleteLater();
        m_initialized = false;
        return false;
    }

    return true;
}

void QGeoTiledMapReplyQGC::_initDataFromResources()
{
    if (_bingNoTileImage.isEmpty()) {
        QFile file(":/res/BingNoTileBytes.dat");
        if (file.open(QFile::ReadOnly)) {
            _bingNoTileImage = file.readAll();
            file.close();
        }
    }

    if (_badTile.isEmpty()) {
        QFile file(":/res/images/notile.png");
        if (file.open(QFile::ReadOnly)) {
            _badTile = file.readAll();
            file.close();
        }
    }
}

void QGeoTiledMapReplyQGC::_networkReplyFinished()
{
    QNetworkReply* const reply = qobject_cast<QNetworkReply*>(sender());
    if (!reply) {
        setError(QGeoTiledMapReply::UnknownError, tr("Unexpected Error"));
        return;
    }
    reply->deleteLater();

    if (reply->error() != QNetworkReply::NoError) {
        return;
    }

    if (!reply->isOpen()) {
        setError(QGeoTiledMapReply::ParseError, tr("Empty Reply"));
        return;
    }

    const int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (!QGCNetworkHelper::isHttpSuccess(statusCode)) {
        setError(QGeoTiledMapReply::CommunicationError, reply->attribute(QNetworkRequest::HttpReasonPhraseAttribute).toString());
        return;
    }

    QByteArray image = reply->readAll();
    if (image.isEmpty()) {
        setError(QGeoTiledMapReply::ParseError, tr("Image is Empty"));
        return;
    }

    const SharedMapProvider mapProvider = UrlFactory::getMapProviderFromQtMapId(tileSpec().mapId());
    if (!mapProvider) {
        setError(QGeoTiledMapReply::UnknownError, tr("Invalid Map Provider"));
        return;
    }

    if (mapProvider->isBingProvider() && (image == _bingNoTileImage)) {
        setError(QGeoTiledMapReply::CommunicationError, tr("Bing Tile Above Zoom Level"));
        return;
    }

    if (mapProvider->isElevationProvider()) {
        const SharedElevationProvider elevationProvider = std::dynamic_pointer_cast<const ElevationProvider>(mapProvider);
        image = elevationProvider->serialize(image);
        if (image.isEmpty()) {
            setError(QGeoTiledMapReply::ParseError, tr("Failed to Serialize Terrain Tile"));
            return;
        }
    }

    _overlayUrl = mapProvider->getOverlayTileURL(tileSpec().x(), tileSpec().y(), tileSpec().zoom());
    if (!_overlayUrl.isEmpty()) {
        // 双层 provider：底图已到手，再去取叠加层，两张合完只落一份缓存。
        _baseImage = image;

        QNetworkRequest overlayRequest = _request;
        overlayRequest.setUrl(_overlayUrl);
        overlayRequest.setOriginatingObject(this);

        QNetworkReply* const overlayReply = _networkManager->get(overlayRequest);
        overlayReply->setParent(this);
        QGCNetworkHelper::ignoreSslErrorsIfNeeded(overlayReply);

        (void) connect(overlayReply, &QNetworkReply::finished, this, &QGeoTiledMapReplyQGC::_overlayReplyFinished);
        (void) connect(this, &QGeoTiledMapReplyQGC::aborted, overlayReply, &QNetworkReply::abort);
        return;
    }

    _finalizeTile(image);
}

void QGeoTiledMapReplyQGC::_overlayReplyFinished()
{
    QNetworkReply* const reply = qobject_cast<QNetworkReply*>(sender());
    const QByteArray base = _baseImage;
    _baseImage.clear();

    QByteArray overlay;
    if (reply) {
        reply->deleteLater();
        if ((reply->error() == QNetworkReply::NoError) && reply->isOpen()
            && QGCNetworkHelper::isHttpSuccess(reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt())) {
            overlay = reply->readAll();
        }
    }

    // 以下每种情况都退回「只有底图」。这是有意为之的降级：少一层路网，好过整块瓦片报错变
    // notile.png —— 后者会让整片地图出现空洞，而前者用户只是暂时看不到路网。
    if (overlay.isEmpty()) {
        qCWarning(QGeoTiledMapReplyQGCLog) << "Overlay unavailable, falling back to base layer" << _overlayUrl;
        _finalizeTile(base);
        return;
    }

    QImage baseImage;
    QImage overlayImage;
    if (!baseImage.loadFromData(base) || !overlayImage.loadFromData(overlay) || (baseImage.size() != overlayImage.size())) {
        qCWarning(QGeoTiledMapReplyQGCLog) << "Overlay size mismatch, falling back to base layer"
                                           << baseImage.size() << overlayImage.size();
        _finalizeTile(base);
        return;
    }

    // 叠加层不透明＝它不是叠加层，是占位图。实测（2026-10-03）：z≥21 时高德把 style=8
    // 302 到 https://webstNN.is.autonavi.com/empty.png，一张 179 B 的**纯色不透明**图；
    // z=19/20 给的是纯透明图（叠上去等于没叠，无害）。不拦这一条，整块瓦片会被涂成一片纯色
    // ——实测 28 张里 12 张如此。
    if (!_hasTransparentPixel(overlayImage)) {
        qCWarning(QGeoTiledMapReplyQGCLog) << "Overlay is fully opaque (placeholder), falling back to base layer" << _overlayUrl;
        _finalizeTile(base);
        return;
    }

    QImage composed = baseImage.convertToFormat(QImage::Format_ARGB32_Premultiplied);
    QPainter painter(&composed);
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
    painter.drawImage(0, 0, overlayImage);
    painter.end();

    // 存 JPEG 不存 PNG：底图是不透明影像，合成结果也是不透明的，照片内容用 PNG 要 133 KB，
    // JPEG q90 只要 36 KB（2026-10-03 z=13 实测），且 QGC 的 Bing Hybrid 瓦片本来就是 JPEG。
    QByteArray composite;
    QBuffer buffer(&composite);
    const bool encoded = buffer.open(QIODevice::WriteOnly) && composed.save(&buffer, "JPEG", 90);
    buffer.close();

    if (!encoded || composite.isEmpty()) {
        qCWarning(QGeoTiledMapReplyQGCLog) << "Overlay encode failed, falling back to base layer";
        _finalizeTile(base);
        return;
    }

    _finalizeTile(composite);
}

void QGeoTiledMapReplyQGC::_finalizeTile(const QByteArray &image)
{
    const SharedMapProvider mapProvider = UrlFactory::getMapProviderFromQtMapId(tileSpec().mapId());
    if (!mapProvider) {
        setError(QGeoTiledMapReply::UnknownError, tr("Invalid Map Provider"));
        return;
    }

    setMapImageData(image);

    const QString format = mapProvider->getImageFormat(image);
    if (format.isEmpty()) {
        setError(QGeoTiledMapReply::ParseError, tr("Unknown Format"));
        return;
    }
    setMapImageFormat(format);

    QGeoFileTileCacheQGC::cacheTile(mapProvider->getMapName(), tileSpec().x(), tileSpec().y(), tileSpec().zoom(), image, format);

    setFinished(true);
}

void QGeoTiledMapReplyQGC::_networkReplyError(QNetworkReply::NetworkError error)
{
    if (error != QNetworkReply::OperationCanceledError) {
        const QNetworkReply* const reply = qobject_cast<const QNetworkReply*>(sender());
        if (!reply) {
            setError(QGeoTiledMapReply::CommunicationError, tr("Invalid Reply"));
        } else {
            setError(QGeoTiledMapReply::CommunicationError, reply->errorString());
        }
    } else {
        setFinished(true);
    }
}

void QGeoTiledMapReplyQGC::_networkReplySslErrors(const QList<QSslError> &errors)
{
    QString errorString;
    for (const QSslError &error : errors) {
        if (!errorString.isEmpty()) {
            (void) errorString.append('\n');
        }
        (void) errorString.append(error.errorString());
    }

    if (!errorString.isEmpty()) {
        setError(QGeoTiledMapReply::CommunicationError, errorString);
    }
}

void QGeoTiledMapReplyQGC::_cacheReply(QGCCacheTile *tile)
{
    if (tile) {
        setMapImageData(tile->img);
        setMapImageFormat(tile->format);
        setCached(true);
        setFinished(true);
        delete tile;
    } else {
        setError(QGeoTiledMapReply::UnknownError, tr("Invalid Cache Tile"));
    }
}

void QGeoTiledMapReplyQGC::_cacheError(QGCMapTask::TaskType type, QStringView errorString)
{
    Q_UNUSED(errorString);

    Q_ASSERT(type == QGCMapTask::TaskType::taskFetchTile);

    if (!QGCNetworkHelper::isInternetAvailable()) {
        setError(QGeoTiledMapReply::CommunicationError, tr("Network Not Available"));
        return;
    }

    _request.setOriginatingObject(this);

    QNetworkReply* const reply = _networkManager->get(_request);
    reply->setParent(this);
    QGCNetworkHelper::ignoreSslErrorsIfNeeded(reply);

    (void) connect(reply, &QNetworkReply::finished, this, &QGeoTiledMapReplyQGC::_networkReplyFinished);
    (void) connect(reply, &QNetworkReply::errorOccurred, this, &QGeoTiledMapReplyQGC::_networkReplyError);
    (void) connect(reply, &QNetworkReply::sslErrors, this, &QGeoTiledMapReplyQGC::_networkReplySslErrors);
    (void) connect(this, &QGeoTiledMapReplyQGC::aborted, reply, &QNetworkReply::abort);
}

void QGeoTiledMapReplyQGC::abort()
{
    QGeoTiledMapReply::abort();
}
