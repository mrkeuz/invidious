class RedditThing
  include JSON::Serializable

  property kind : String
  property data : RedditComment | RedditLink | RedditMore | RedditListing
end

class RedditComment
  include JSON::Serializable

  property author : String
  property body_html : String
  property replies : RedditThing | String
  property score : Int32
  property depth : Int32
  property permalink : String

  @[JSON::Field(converter: RedditComment::TimeConverter)]
  property created_utc : Time

  module TimeConverter
    def self.from_json(value : JSON::PullParser) : Time
      Time.unix(value.read_float.to_i)
    end

    def self.to_json(value : Time, json : JSON::Builder)
      json.number(value.to_unix)
    end
  end
end

struct RedditLink
  include JSON::Serializable

  property author : String
  property score : Int32
  property subreddit : String
  property num_comments : Int32
  property id : String
  property permalink : String
  property title : String
end

struct RedditMore
  include JSON::Serializable

  property children : Array(String)
  property count : Int32
  property depth : Int32
end

class RedditListing
  include JSON::Serializable

  property children : Array(RedditThing)
  property modhash : String
end

def fetch_youtube_comments(id, cursor, format, locale, thin_mode, region, sort_by = "top")
  case cursor
  when nil, ""
    ctoken = produce_comment_continuation(id, cursor: "", sort_by: sort_by)
  when .starts_with? "ADSJ"
    ctoken = produce_comment_continuation(id, cursor: cursor, sort_by: sort_by)
  else
    ctoken = cursor
  end

  client_config = YoutubeAPI::ClientConfig.new(region: region)
  response = YoutubeAPI.next(continuation: ctoken, client_config: client_config)
  contents = nil

  if on_response_received_endpoints = response["onResponseReceivedEndpoints"]?
    header = nil
    on_response_received_endpoints.as_a.each do |item|
      if item["reloadContinuationItemsCommand"]?
        case item["reloadContinuationItemsCommand"]["slot"]
        when "RELOAD_CONTINUATION_SLOT_HEADER"
          header = item["reloadContinuationItemsCommand"]["continuationItems"][0]
        when "RELOAD_CONTINUATION_SLOT_BODY"
          # continuationItems is nil when video has no comments
          contents = item["reloadContinuationItemsCommand"]["continuationItems"]?
        end
      elsif item["appendContinuationItemsAction"]?
        contents = item["appendContinuationItemsAction"]["continuationItems"]
      end
    end
  elsif response["continuationContents"]?
    response = response["continuationContents"]
    if response["commentRepliesContinuation"]?
      body = response["commentRepliesContinuation"]
    else
      body = response["itemSectionContinuation"]
    end
    contents = body["contents"]?
    header = body["header"]?
  else
    raise InfoException.new("Could not fetch comments")
  end

  if !contents
    if format == "json"
      return {"comments" => [] of String}.to_json
    else
      return {"contentHtml" => "", "commentCount" => 0}.to_json
    end
  end

  continuation_item_renderer = nil
  contents.as_a.reject! do |item|
    if item["continuationItemRenderer"]?
      continuation_item_renderer = item["continuationItemRenderer"]
      true
    end
  end

  response = JSON.build do |json|
    json.object do
      if header
        count_text = header["commentsHeaderRenderer"]["countText"]
        comment_count = (count_text["simpleText"]? || count_text["runs"]?.try &.[0]?.try &.["text"]?)
          .try &.as_s.gsub(/\D/, "").to_i? || 0
        json.field "commentCount", comment_count
      end

      json.field "videoId", id

      json.field "comments" do
        json.array do
          contents.as_a.each do |node|
            json.object do
              if node["commentThreadRenderer"]?
                node = node["commentThreadRenderer"]
              end

              if node["replies"]?
                node_replies = node["replies"]["commentRepliesRenderer"]
              end

              if node["comment"]?
                node_comment = node["comment"]["commentRenderer"]
              else
                node_comment = node["commentRenderer"]
              end

              content_html = node_comment["contentText"]?.try { |t| parse_content(t) } || ""
              author = node_comment["authorText"]?.try &.["simpleText"]? || ""

              json.field "author", author
              json.field "authorThumbnails" do
                json.array do
                  node_comment["authorThumbnail"]["thumbnails"].as_a.each do |thumbnail|
                    json.object do
                      json.field "url", thumbnail["url"]
                      json.field "width", thumbnail["width"]
                      json.field "height", thumbnail["height"]
                    end
                  end
                end
              end

              if node_comment["authorEndpoint"]?
                json.field "authorId", node_comment["authorEndpoint"]["browseEndpoint"]["browseId"]
                json.field "authorUrl", node_comment["authorEndpoint"]["browseEndpoint"]["canonicalBaseUrl"]
              else
                json.field "authorId", ""
                json.field "authorUrl", ""
              end

              published_text = node_comment["publishedTimeText"]["runs"][0]["text"].as_s
              published = decode_date(published_text.rchop(" (edited)"))

              if published_text.includes?(" (edited)")
                json.field "isEdited", true
              else
                json.field "isEdited", false
              end

              json.field "content", html_to_content(content_html)
              json.field "contentHtml", content_html

              json.field "published", published.to_unix
              json.field "publishedText", translate(locale, "`x` ago", recode_date(published, locale))

              comment_action_buttons_renderer = node_comment["actionButtons"]["commentActionButtonsRenderer"]

              json.field "likeCount", comment_action_buttons_renderer["likeButton"]["toggleButtonRenderer"]["accessibilityData"]["accessibilityData"]["label"].as_s.scan(/\d/).map(&.[0]).join.to_i
              json.field "commentId", node_comment["commentId"]
              json.field "authorIsChannelOwner", node_comment["authorIsChannelOwner"]

              if comment_action_buttons_renderer["creatorHeart"]?
                hearth_data = comment_action_buttons_renderer["creatorHeart"]["creatorHeartRenderer"]["creatorThumbnail"]
                json.field "creatorHeart" do
                  json.object do
                    json.field "creatorThumbnail", hearth_data["thumbnails"][-1]["url"]
                    json.field "creatorName", hearth_data["accessibility"]["accessibilityData"]["label"]
                  end
                end
              end

              if node_replies && !response["commentRepliesContinuation"]?
                if node_replies["moreText"]?
                  reply_count = (node_replies["moreText"]["simpleText"]? || node_replies["moreText"]["runs"]?.try &.[0]?.try &.["text"]?)
                    .try &.as_s.gsub(/\D/, "").to_i? || 1
                elsif node_replies["viewReplies"]?
                  reply_count = node_replies["viewReplies"]["buttonRenderer"]["text"]?.try &.["runs"][1]?.try &.["text"]?.try &.as_s.to_i? || 1
                else
                  reply_count = 1
                end

                if node_replies["continuations"]?
                  continuation = node_replies["continuations"]?.try &.as_a[0]["nextContinuationData"]["continuation"].as_s
                elsif node_replies["contents"]?
                  continuation = node_replies["contents"]?.try &.as_a[0]["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].as_s
                end
                continuation ||= ""

                json.field "replies" do
                  json.object do
                    json.field "replyCount", reply_count
                    json.field "continuation", continuation
                  end
                end
              end
            end
          end
        end
      end

      if continuation_item_renderer
        if continuation_item_renderer["continuationEndpoint"]?
          continuation_endpoint = continuation_item_renderer["continuationEndpoint"]
        elsif continuation_item_renderer["button"]?
          continuation_endpoint = continuation_item_renderer["button"]["buttonRenderer"]["command"]
        end
        if continuation_endpoint
          json.field "continuation", continuation_endpoint["continuationCommand"]["token"].as_s
        end
      end
    end
  end

  if format == "html"
    response = JSON.parse(response)
    content_html = template_youtube_comments(response, locale, thin_mode)

    response = JSON.build do |json|
      json.object do
        json.field "contentHtml", content_html

        if response["commentCount"]?
          json.field "commentCount", response["commentCount"]
        else
          json.field "commentCount", 0
        end
      end
    end
  end

  return response
end

def fetch_reddit_comments(id, sort_by = "confidence")
  client = make_client(REDDIT_URL)
  headers = HTTP::Headers{"User-Agent" => "web:invidious:v#{CURRENT_VERSION} (by github.com/iv-org/invidious)"}

  # TODO: Use something like #479 for a static list of instances to use here
  query = URI::Params.encode({q: "(url:3D#{id} OR url:#{id}) AND (site:invidio.us OR site:youtube.com OR site:youtu.be)"})
  search_results = client.get("/search.json?#{query}", headers)

  if search_results.status_code == 200
    search_results = RedditThing.from_json(search_results.body)

    # For videos that have more than one thread, choose the one with the highest score
    threads = search_results.data.as(RedditListing).children
    thread = threads.max_by?(&.data.as(RedditLink).score).try(&.data.as(RedditLink))
    result = thread.try do |t|
      body = client.get("/r/#{t.subreddit}/comments/#{t.id}.json?limit=100&sort=#{sort_by}", headers).body
      Array(RedditThing).from_json(body)
    end
    result ||= [] of RedditThing
  elsif search_results.status_code == 302
    # Previously, if there was only one result then the API would redirect to that result.
    # Now, it appears it will still return a listing so this section is likely unnecessary.

    result = client.get(search_results.headers["Location"], headers).body
    result = Array(RedditThing).from_json(result)

    thread = result[0].data.as(RedditListing).children[0].data.as(RedditLink)
  else
    raise InfoException.new("Could not fetch comments")
  end

  client.close

  comments = result[1]?.try(&.data.as(RedditListing).children)
  comments ||= [] of RedditThing
  return comments, thread
end

def template_youtube_comments(comments, locale, thin_mode, is_replies = false)
  String.build do |html|
    root = comments["comments"].as_a
    root.each do |child|
      if child["replies"]?
        replies_count_text = translate_count(locale,
          "comments_view_x_replies",
          child["replies"]["replyCount"].as_i64 || 0,
          NumberFormatting::Separator
        )

        replies_html = <<-END_HTML
        <div id="replies" class="pure-g">
          <div class="pure-u-1-24"></div>
          <div class="pure-u-23-24">
            <p>
              <a href="javascript:void(0)" data-continuation="#{child["replies"]["continuation"]}"
                data-onclick="get_youtube_replies" data-load-replies>#{replies_count_text}</a>
            </p>
          </div>
        </div>
        END_HTML
      end

      if !thin_mode
        author_thumbnail = "/ggpht#{URI.parse(child["authorThumbnails"][-1]["url"].as_s).request_target}"
      else
        author_thumbnail = ""
      end

      author_name = HTML.escape(child["author"].as_s)

      html << <<-END_HTML
      <div class="pure-g" style="width:100%">
        <div class="channel-profile pure-u-4-24 pure-u-md-2-24">
          <img loading="lazy" style="margin-right:1em;margin-top:1em;width:90%" src="#{author_thumbnail}">
        </div>
        <div class="pure-u-20-24 pure-u-md-22-24">
          <p>
            <b>
              <a class="#{child["authorIsChannelOwner"] == true ? "channel-owner" : ""}" href="#{child["authorUrl"]}">#{author_name}</a>
            </b>
            <p style="white-space:pre-wrap">#{child["contentHtml"]}</p>
      END_HTML

      if child["attachment"]?
        attachment = child["attachment"]

        case attachment["type"]
        when "image"
          attachment = attachment["imageThumbnails"][1]

          html << <<-END_HTML
          <div class="pure-g">
            <div class="pure-u-1 pure-u-md-1-2">
              <img loading="lazy" style="width:100%" src="/ggpht#{URI.parse(attachment["url"].as_s).request_target}">
            </div>
          </div>
          END_HTML
        when "video"
          html << <<-END_HTML
            <div class="pure-g">
              <div class="pure-u-1 pure-u-md-1-2">
                <div style="position:relative;width:100%;height:0;padding-bottom:56.25%;margin-bottom:5px">
          END_HTML

          if attachment["error"]?
            html << <<-END_HTML
              <p>#{attachment["error"]}</p>
            END_HTML
          else
            html << <<-END_HTML
              <iframe id='ivplayer' style='position:absolute;width:100%;height:100%;left:0;top:0' src='/embed/#{attachment["videoId"]?}?autoplay=0' style='border:none;'></iframe>
            END_HTML
          end

          html << <<-END_HTML
                </div>
              </div>
            </div>
          END_HTML
        else nil # Ignore
        end
      end

      html << <<-END_HTML
        <span title="#{Time.unix(child["published"].as_i64).to_s(translate(locale, "%A %B %-d, %Y"))}">#{translate(locale, "`x` ago", recode_date(Time.unix(child["published"].as_i64), locale))} #{child["isEdited"] == true ? translate(locale, "(edited)") : ""}</span>
        |
      END_HTML

      if comments["videoId"]?
        html << <<-END_HTML
          <a href="https://www.youtube.com/watch?v=#{comments["videoId"]}&lc=#{child["commentId"]}" title="#{translate(locale, "YouTube comment permalink")}">[YT]</a>
          |
        END_HTML
      elsif comments["authorId"]?
        html << <<-END_HTML
          <a href="https://www.youtube.com/channel/#{comments["authorId"]}/community?lb=#{child["commentId"]}" title="#{translate(locale, "YouTube comment permalink")}">[YT]</a>
          |
        END_HTML
      end

      html << <<-END_HTML
        <i class="icon ion-ios-thumbs-up"></i> #{number_with_separator(child["likeCount"])}
      END_HTML

      if child["creatorHeart"]?
        if !thin_mode
          creator_thumbnail = "/ggpht#{URI.parse(child["creatorHeart"]["creatorThumbnail"].as_s).request_target}"
        else
          creator_thumbnail = ""
        end

        html << <<-END_HTML
          <span class="creator-heart-container" title="#{translate(locale, "`x` marked it with a ❤", child["creatorHeart"]["creatorName"].as_s)}">
              <div class="creator-heart">
                  <img loading="lazy" class="creator-heart-background-hearted" src="#{creator_thumbnail}"></img>
                  <div class="creator-heart-small-hearted">
                      <div class="icon ion-ios-heart creator-heart-small-container"></div>
                  </div>
              </div>
          </span>
        END_HTML
      end

      html << <<-END_HTML
          </p>
          #{replies_html}
        </div>
      </div>
      END_HTML
    end

    if comments["continuation"]?
      html << <<-END_HTML
      <div class="pure-g">
        <div class="pure-u-1">
          <p>
            <a href="javascript:void(0)" data-continuation="#{comments["continuation"]}"
              data-onclick="get_youtube_replies" data-load-more #{"data-load-replies" if is_replies}>#{translate(locale, "Load more")}</a>
          </p>
        </div>
      </div>
      END_HTML
    end
  end
end

def template_reddit_comments(root, locale)
  String.build do |html|
    root.each do |child|
      if child.data.is_a?(RedditComment)
        child = child.data.as(RedditComment)
        body_html = HTML.unescape(child.body_html)

        replies_html = ""
        if child.replies.is_a?(RedditThing)
          replies = child.replies.as(RedditThing)
          replies_html = template_reddit_comments(replies.data.as(RedditListing).children, locale)
        end

        if child.depth > 0
          html << <<-END_HTML
          <div class="pure-g">
          <div class="pure-u-1-24">
          </div>
          <div class="pure-u-23-24">
          END_HTML
        else
          html << <<-END_HTML
          <div class="pure-g">
          <div class="pure-u-1">
          END_HTML
        end

        html << <<-END_HTML
        <p>
          <a href="javascript:void(0)" data-onclick="toggle_parent">[ - ]</a>
          <b><a href="https://www.reddit.com/user/#{child.author}">#{child.author}</a></b>
          #{translate_count(locale, "comments_points_count", child.score, NumberFormatting::Separator)}
          <span title="#{child.created_utc.to_s(translate(locale, "%a %B %-d %T %Y UTC"))}">#{translate(locale, "`x` ago", recode_date(child.created_utc, locale))}</span>
          <a href="https://www.reddit.com#{child.permalink}" title="#{translate(locale, "permalink")}">#{translate(locale, "permalink")}</a>
          </p>
          <div>
          #{body_html}
          #{replies_html}
        </div>
        </div>
        </div>
        END_HTML
      end
    end
  end
end

def replace_links(html)
  html = XML.parse_html(html)

  html.xpath_nodes(%q(//a)).each do |anchor|
    url = URI.parse(anchor["href"])

    if url.host.nil? || url.host.not_nil!.ends_with?("youtube.com") || url.host.not_nil!.ends_with?("youtu.be")
      if url.host.try &.ends_with? "youtu.be"
        url = "/watch?v=#{url.path.lstrip('/')}#{url.query_params}"
      else
        if url.path == "/redirect"
          params = HTTP::Params.parse(url.query.not_nil!)
          anchor["href"] = params["q"]?
        else
          anchor["href"] = url.request_target
        end
      end
    elsif url.to_s == "#"
      begin
        length_seconds = decode_length_seconds(anchor.content)
      rescue ex
        length_seconds = decode_time(anchor.content)
      end

      if length_seconds > 0
        anchor["href"] = "javascript:void(0)"
        anchor["onclick"] = "player.currentTime(#{length_seconds})"
      else
        anchor["href"] = url.request_target
      end
    end
  end

  html = html.xpath_node(%q(//body)).not_nil!
  if node = html.xpath_node(%q(./p))
    html = node
  end

  return html.to_xml(options: XML::SaveOptions::NO_DECL)
end

def fill_links(html, scheme, host)
  html = XML.parse_html(html)

  html.xpath_nodes("//a").each do |match|
    url = URI.parse(match["href"])
    # Reddit links don't have host
    if !url.host && !match["href"].starts_with?("javascript") && !url.to_s.ends_with? "#"
      url.scheme = scheme
      url.host = host
      match["href"] = url
    end
  end

  if host == "www.youtube.com"
    html = html.xpath_node(%q(//body/p)).not_nil!
  end

  return html.to_xml(options: XML::SaveOptions::NO_DECL)
end

def parse_content(content : JSON::Any) : String
  content["simpleText"]?.try &.as_s.rchop('\ufeff').try { |b| HTML.escape(b) }.to_s ||
    content["runs"]?.try &.as_a.try { |r| content_to_comment_html(r).try &.to_s.gsub("\n", "<br>") } || ""
end

def content_to_comment_html(content)
  comment_html = content.map do |run|
    text = HTML.escape(run["text"].as_s)

    if run["bold"]?
      text = "<b>#{text}</b>"
    end

    if run["italics"]?
      text = "<i>#{text}</i>"
    end

    if run["navigationEndpoint"]?
      if url = run["navigationEndpoint"]["urlEndpoint"]?.try &.["url"].as_s
        url = URI.parse(url)

        if url.host == "youtu.be"
          url = "/watch?v=#{url.request_target.lstrip('/')}"
        elsif url.host.nil? || url.host.not_nil!.ends_with?("youtube.com")
          if url.path == "/redirect"
            # Sometimes, links can be corrupted (why?) so make sure to fallback
            # nicely. See https://github.com/iv-org/invidious/issues/2682
            url = HTTP::Params.parse(url.query.not_nil!)["q"]? || ""
          else
            url = url.request_target
          end
        end

        text = %(<a href="#{url}">#{text}</a>)
      elsif watch_endpoint = run["navigationEndpoint"]["watchEndpoint"]?
        length_seconds = watch_endpoint["startTimeSeconds"]?
        video_id = watch_endpoint["videoId"].as_s

        if length_seconds && length_seconds.as_i > 0
          text = %(<a href="javascript:void(0)" data-onclick="jump_to_time" data-jump-time="#{length_seconds}">#{text}</a>)
        else
          text = %(<a href="/watch?v=#{video_id}">#{text}</a>)
        end
      elsif url = run.dig?("navigationEndpoint", "commandMetadata", "webCommandMetadata", "url").try &.as_s
        text = %(<a href="#{url}">#{text}</a>)
      end
    end

    text
  end.join("").delete('\ufeff')

  return comment_html
end

def produce_comment_continuation(video_id, cursor = "", sort_by = "top")
  object = {
    "2:embedded" => {
      "2:string"    => video_id,
      "25:varint"   => 0_i64,
      "28:varint"   => 1_i64,
      "36:embedded" => {
        "5:varint" => -1_i64,
        "8:varint" => 0_i64,
      },
      "40:embedded" => {
        "1:varint" => 4_i64,
        "3:string" => "https://www.youtube.com",
        "4:string" => "",
      },
    },
    "3:varint"   => 6_i64,
    "6:embedded" => {
      "1:string"   => cursor,
      "4:embedded" => {
        "4:string" => video_id,
        "6:varint" => 0_i64,
      },
      "5:varint" => 20_i64,
    },
  }

  case sort_by
  when "top"
    object["6:embedded"].as(Hash)["4:embedded"].as(Hash)["6:varint"] = 0_i64
  when "new", "newest"
    object["6:embedded"].as(Hash)["4:embedded"].as(Hash)["6:varint"] = 1_i64
  else # top
    object["6:embedded"].as(Hash)["4:embedded"].as(Hash)["6:varint"] = 0_i64
  end

  continuation = object.try { |i| Protodec::Any.cast_json(i) }
    .try { |i| Protodec::Any.from_json(i) }
    .try { |i| Base64.urlsafe_encode(i) }
    .try { |i| URI.encode_www_form(i) }

  return continuation
end
