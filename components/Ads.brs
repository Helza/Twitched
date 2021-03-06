' Copyright (C) 2017-2018 Rolando Islas. All Rights Reserved.

#if enable_ads

Library "Roku_Ads.brs"

' Ads entry point
function init() as void
    ' Constants
    m.PORT = createObject("roMessagePort")
    ' Ads
    m.ads = Roku_Ads()
    m.ads.enableNielsenDar(true)
    m.ads.enableAdMeasurements(true)
    m.ads.setNielsenAppId(m.global.secret.ad_nielsen_id)
    m.ads.setAdPrefs(true, 2)
    ' Components
    m.twitch_api = m.top.findNode("twitch_api")
    ' Events
    m.top.observeField("show_ads", m.PORT)
    m.twitch_api.observeField("result", m.PORT)
    ' Init
    init_logging()
    m.twitch_api.get_ad_server = "on_ad_server"
    ' Variables
    m.did_fetch_server = false
    m.ad_url = ""
    m.ad_play_times = {}
    ' Task init
    m.top.functionName = "run"
    m.top.control = "RUN"
end function

' Set the ad url of the Roku_Ads instance
function set_ad_url(ad_url as string) as void
    m.ads.setAdUrl(ad_url.replace("ROKU_ADS_TRACKING_ID_OBEY_LIMIT", get_ad_id()))
end function

' Handle ad server request data from Twitched's API
function on_ad_server(event as object) as void
    ad_server = event.getData().result
    if type(ad_server) <> "roAssociativeArray" or (type(ad_server.ad_server) <> "roString" and type(ad_server.ad_server) <> "String")
        printl(m.DEBUG, "Ads: Failed to fetch ad server from Twitched API")
        return
    end if
    printl(m.DEBUG, "Ads: Fetched ad server from Twitched API")
    m.did_fetch_server = true
    m.ad_url = ad_server.ad_server
    set_ad_url(ad_server.ad_server)
end function

' Get the ad id for the device, obeying limited ad tracking
function get_ad_id() as string
    ad_id = ""
    device_info = createObject("roDeviceInfo")
    if not device_info.isRidaDisabled()
        ad_id = device_info.getRida()
    end if
    return ad_id
end function

' Main task function
function run() as void
    printl(m.DEBUG, "Ads: Ads task started")
    while true
        msg = wait(0, m.PORT)
        ' Field event
        if type(msg) = "roSGNodeEvent"
            if msg.getField() = "show_ads"
                show_ads(msg.getData())
            else if msg.getField() = "result"
                on_callback(msg)
            end if
        end if
    end while
end function

' Handle callback
function on_callback(event as object) as void
    callback = event.getData().callback
    if callback = "on_ad_server"
        on_ad_server(event)
    else
        if callback = invalid
            callback = ""
        end if
        printl(m.WARN, "on_callback: Unhandled callback: " + callback)
    end if
end function

' Async show ads call
' Sets the status to the result of the ad call
' @param params roArray [nielsen_id  as string, genre as string,
' content_length as integer, is_vod as boolean]
function show_ads(params as object) as void
    m.top.showing_ads = true
    if not m.did_fetch_server
        m.twitch_api.get_ad_server = "on_ad_server"
    end if
    nielsen_id = params[0]
    genre = params[1]
    content_length = params[2]
    is_vod = params[3]

    ' Check last ad time for a channel
    if does_channel_have_ad_cooldown(nielsen_id)
        m.top.setField("status", true)
        m.top.showing_ads = false
        return
    end if

    ' Normal ad flow
    set_ad_url(m.ad_url)
    m.ads.setNielsenProgramId(nielsen_id) ' Streamer
    m.ads.setNielsenGenre(genre) ' General variety
    m.ads.setContentId(nielsen_id)
    m.ads.setContentGenre("Entertainment")
    if content_length > 0
        m.ads.setContentLength(content_length) ' Seconds
    else
        m.ads.setContentLength() ' Clear
    end if
    max_ads = m.global.twitched_config.ad_limit_stream
    if is_vod
        max_ads = m.global.twitched_config.ad_limit_vod
    end if
    ads = get_ads(max_ads)
    ad_pods = ads["ad_pods"]
    ad_count = ads["count"]
    track_ads(ad_count, false)
    if ad_count = 0
        printl(m.DEBUG, "Ads: No ads loaded from third-party ad server")
        ' Load Roku ads as a fallback
        set_ad_url("")
        ads = get_ads(max_ads)
        ad_pods = ads["ad_pods"]
        ad_count = ads["count"]
        track_ads(ad_count, true)
        if ad_count = 0
            printl(m.DEBUG, "Ads: No ads loaded from Roku ad server")
            m.top.setField("status", true)
            return
        end if
    end if
    printl(m.DEBUG, "Ads: Showing " + ad_count.toStr() + " ads")
    did_ads_play = m.ads.showAds(ad_pods, invalid, m.top.view)
    if did_ads_play
        m.ad_play_times[nielsen_id] = uptime(0)
    end if
    m.top.setField("status", did_ads_play)
    m.top.showing_ads = false
end function

' Returns true if the channel has played an ad in the last 5 minutes.
' An ad should not be played if this is the case.
function does_channel_have_ad_cooldown(key as string) as boolean
    ' Clean old times
    to_delete = []
    for each time_key in m.ad_play_times.keys()
        if uptime(0) - m.ad_play_times[time_key] >= 5 * 60
            to_delete.push(time_key)
        end if
    end for
    for each time_key in to_delete
        m.ad_play_times.delete(time_key)
    end for
    ' Check time
    return m.ad_play_times.doesExist(key)
end function

' Get the ads from the current ad server.
' @return associative array containing ad pods and the total ad count
' The ad_pods array may be invalid
' {
'   ad_pods: [...],
'   count: 0
' }
' An array of ad pods will be returned with the most ads contained total equal
' to the total allowed per ad bread, passed as the first argument.
function get_ads(max_ads as integer) as object
    if max_ads < 1
        printl(m.DEBUG, "Ads: Max ads set to less than 1. Forcing 2")
        max_ads = 2 ' Load two if for some reason max_ads is 0 or less
    end if
    ret_ad_pods = []
    ad_count = 0
    ad_pods = m.ads.getAds()
    if type(ad_pods) <> "roArray"
        return {
            ad_pods: invalid,
            count: 0
        }
    end if
    for each ad_pod in ad_pods
        if type(ad_pod) = "roAssociativeArray" and ad_count < max_ads
            allowed_ads = []
            duration = 0
            ads = ad_pod["ads"]
            ' Populate an array of ads for this pod
            if type(ads) = "roArray"
                max_index = min(max_ads - ad_count - 1, ads.count() - 1)
                for ad_index = 0 to max_index
                    ad = ads[ad_index]
                    ad_duration = ad["duration"]
                    if ad_duration <> invalid
                        duration = duration + ad_duration
                        allowed_ads.push(ad)
                    end if
                end for
            end if
            ' Add this pod to the ad pods to return
            if allowed_ads.count() > 0
                ad_pod["ads"] = allowed_ads
                ad_pod["duration"] = duration
                ad_count = ad_count + allowed_ads.count()
                ret_ad_pods.push(ad_pod)
            end if
        end if
    end for
    ' Return ad pods
    if ad_count > 0
        return {
            ad_pods: ret_ad_pods,
            count: ad_count
        }
    end if
    return {
        ad_pods: invalid,
        count: 0
    }
end function

' Send analytics data about how many ads were received for playback
function track_ads(ads_count as integer, from_roku as boolean) as void
    m.global.analytics.trackEvent = {
        google: {
            ec: "Ad",
            ea: "Ads Started",
            el: "Count: " + ads_count.toStr() + ", From Roku: " + from_roku.toStr()
        }
    }
end function

#else

    function init() as void
    end function

#end if
