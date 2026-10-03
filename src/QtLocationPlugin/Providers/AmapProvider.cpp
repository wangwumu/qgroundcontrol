#include "AmapProvider.h"

QString AmapProvider::_buildUrl(int x, int y, int zoom, const QString &query) const
{
    // _getServerNum() 给出 0..3；高德的瓦片服务器编号是 01..04（00/05 均不可达，已实测），
    // 所以 +1 之后再补前导零。
    const int serverNum = _getServerNum(x, y, 4) + 1;

    return _mapUrl
        .arg(_host)
        .arg(serverNum, 2, 10, QLatin1Char('0'))
        .arg(query)
        .arg(x)
        .arg(y)
        .arg(zoom);
}

QString AmapProvider::_getURL(int x, int y, int zoom) const
{
    return _buildUrl(x, y, zoom, _query);
}

QString AmapProvider::_getOverlayURL(int x, int y, int zoom) const
{
    if (_overlayQuery.isEmpty()) {
        return QString();
    }

    return _buildUrl(x, y, zoom, _overlayQuery);
}
