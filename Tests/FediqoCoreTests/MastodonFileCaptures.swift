import Foundation

/// What a Mastodon 4.6.6 says of a file on its way to a post (#438), **as a real server sent it**.
///
/// Asked with `curl` on 2026-11-02 of the image `servers/compose.yml` pins, under its own compose
/// project, thrown away after, with a short video (`video/mp4`). Its worker was stopped, so the
/// file stayed in preparation, then the worker's own job was run where the file was, as a worker
/// sharing its disk would. The `mastodon-sidekiq` of the compose file shares no disk with the web
/// container: on it this file **really failed**, which is the 422 below.
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | `POST /api/v2/media`, a video | 202, `url` null |
/// | `POST /api/v2/media`, a picture | 200, `url` set |
/// | `GET /api/v1/media/:id` being prepared | 206, `url` null |
/// | the same once ready | 200, `url` set |
/// | the same where it could not be prepared | 422 `Error processing thumbnail for uploaded media` |
/// | the same of another's, of none, or of one on a post | 404 `Record not found` |
/// | `PUT /api/v1/media/:id` `description`, being prepared | 206, and it is said |
/// | the same, ready | 200 |
/// | the same, could not be prepared | 422, as `GET` |
/// | the same, on a post | 404 |
/// | `DELETE /api/v1/media/:id`, at every stage not on a post | 200 `{}`; then `GET` and `DELETE` 404 |
/// | the same, on a post | 422 `Media attachment is currently used by a status` |
/// | `POST /api/v1/statuses` carrying one being prepared, or could not be | 422 `Cannot attach files that have not finished processing. Try again in a moment!` |
/// | the same, ready | 200 |
enum MastodonFileCaptures {
    static let accepted = #"""
{"id":"117546240585304779","type":"gifv","url":null,"preview_url":"https://mastodon.localhost/system/media_attachments/files/117/546/240/585/304/779/small/2ea0cf793b411377.png","remote_url":null,"preview_remote_url":null,"text_url":null,"meta":{"original":{"width":320,"height":240,"frame_rate":"10/1","duration":3.0,"bitrate":38461},"small":{"width":320,"height":240,"size":"320x240","aspect":1.3333333333333333}},"description":"first","blurhash":"U.KeN0M-rvKos:RqS{XLjYn2r@V_kBoInkjc"}
"""#

    static let ready = #"""
{"id":"117546247013100785","type":"gifv","url":"https://mastodon.localhost/system/media_attachments/files/117/546/247/013/100/785/original/52ce5b34079f1597.mp4","preview_url":"https://mastodon.localhost/system/media_attachments/files/117/546/247/013/100/785/small/52ce5b34079f1597.png","remote_url":null,"preview_remote_url":null,"text_url":null,"meta":{"original":{"width":320,"height":240,"frame_rate":"10/1","duration":3.0,"bitrate":38464},"small":{"width":320,"height":240,"size":"320x240","aspect":1.3333333333333333}},"description":"first","blurhash":"U.KeN0M-rvKos:RqS{XLjYn2r@V_kBoInkjc"}
"""#

    static let unprepared = #"""
{"error":"Error processing thumbnail for uploaded media"}
"""#

    static let onAPost = #"""
{"error":"Media attachment is currently used by a status"}
"""#

    static let notFound = #"""
{"error":"Record not found"}
"""#
}
