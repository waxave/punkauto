# frozen_string_literal: true

module Punkauto
  # Utility module for extracting part information from HTML.
  module PartExtractor
    module_function

    BRAND_PATTERNS = [
      /(?:Brand|Mfg|Manufacturer)\s*:?\s*([A-Z][a-zA-Z\s&]{2,20})/i,
      /\b(HONDA|TOYOTA|FORD|CHEVROLET|NISSAN|BMW|MERCEDES|AUDI|LEXUS|ACURA|INFINITI)\b/i,
      /\b(BOSCH|DENSO|NGK|MOBIL|CASTROL|VALVOLINE|MONROE|KYB|BILSTEIN|BREMBO|ATE|ZIMMERMANN|DELPHI|GATES|DAYCO|HOLSTEIN|ULTRA-POWER|AUTOTECNICA|FAMOUS)\b/i
    ].freeze

    PART_NUMBER_PATTERNS = [
      /(?:Part|P\/N|PN|#)\s*:?\s*([A-Z0-9\-]{4,})/i,
      /\b([A-Z]{2,}[0-9]{3,}[A-Z0-9\-]*)\b/,
      /\b([0-9]{3,}[A-Z]{2,}[A-Z0-9\-]*)\b/,
      /\b([A-Z0-9\-]{6,})\b/
    ].freeze

    PRICE_PATTERNS = [
      /\$([0-9,]+\.?[0-9]*)/,
      /USD\s*([0-9,]+\.?[0-9]*)/i,
      /Price:\s*\$([0-9,]+\.?[0-9]*)/i
    ].freeze

    VIDEO_PATTERNS = [
      /youtube\.com\/watch\?v=([a-zA-Z0-9_-]+)/,
      /youtu\.be\/([a-zA-Z0-9_-]+)/,
      /vimeo\.com\/([0-9]+)/,
      /\.mp4['"]?/,
      /\.webm['"]?/,
      /\.mov['"]?/
    ].freeze

    NOISE_PATTERNS = ["Info", "Fits", "Related Parts", "Intentionally blank"].freeze

    def extract_from_element(element)
      text = node_text(element)
      return nil if text.empty? || text.length < 3

      href = element["href"] || ""

      nav_words = %w[show hide expand collapse toggle]
      return nil if nav_words.any? { |word| text.downcase.include?(word) }

      part_number = "Unknown"
      price = nil
      brand = nil

      PRICE_PATTERNS.each do |pattern|
        match = text.match(pattern)
        if match
          price = "$#{match[1]}"
          break
        end
      end

      PART_NUMBER_PATTERNS.each do |pattern|
        match = text.match(pattern)
        if match
          potential = match[1]
          if potential.match?(/[0-9]/) && potential.length >= 4
            part_number = potential
            break
          end
        end
      end

      BRAND_PATTERNS.each do |pattern|
        match = text.match(pattern)
        if match
          brand = titlecase(match[1])
          break
        end
      end

      clean_name = clean_name_for(text, price, part_number, brand)
      full_url = format_url(href)

      PartInfo.new(
        name: clean_name.empty? ? text : clean_name,
        part_number: part_number,
        price: price,
        brand: brand,
        url: full_url,
        image_url: nil,
        info_url: nil,
        video_url: nil
      )
    rescue StandardError
      nil
    end

    def extract_from_table_row(row, cells)
      cell_texts = cells.map { |cell| node_text(cell) }

      info = {
        name: nil,
        part_number: "Unknown",
        price: nil,
        brand: nil,
        url: nil,
        image_url: nil,
        info_url: nil,
        video_url: nil
      }

      cell_texts.each do |cell_text|
        match = cell_text.match(PRICE_PATTERNS[0])
        if match
          info[:price] = "$#{match[1]}"
          break
        end
      end

      cell_texts.each do |cell_text|
        match = cell_text.match(/\b[A-Z0-9\-]{6,}\b/)
        if match && !cell_text.include?("$")
          info[:part_number] = match[0]
          break
        end
      end

      brands = %w[DENSO BOSCH NGK HONDA TOYOTA FORD CHEVROLET DELPHI GATES DAYCO MONROE KYB BILSTEIN BREMBO HOLSTEIN ULTRA-POWER AUTOTECNICA FAMOUS]
      cell_texts.each do |cell_text|
        brands.each do |brand|
          if cell_text.upcase.include?(brand)
            info[:brand] = brand
            break
          end
        end
        break if info[:brand]
      end

      name_candidates = cell_texts.select { |text| !text.empty? && !text.include?("$") && text.length > 5 }
      unless name_candidates.empty?
        longest = name_candidates.max_by(&:length)
        clean = clean_part_name(longest, info[:brand], info[:part_number])
        info[:name] = clean.empty? ? longest : clean
      end

      extract_urls_from_row(row, info)

      return nil unless info[:price] || info[:part_number] != "Unknown"

      PartInfo.new(
        name: info[:name] || "Unknown Part",
        part_number: info[:part_number],
        price: info[:price],
        brand: info[:brand],
        url: info[:url],
        image_url: info[:image_url],
        info_url: info[:info_url],
        video_url: info[:video_url]
      )
    rescue StandardError
      nil
    end

    # Extract a part from a listing node (DIV- or TBODY-based).
    def extract_from_listing(listing, name: nil)
      brand = nil
      part_number = "Unknown"
      price = nil
      image_url = nil
      info_url = nil

      brand_node = listing.at_css(".listing-final-manufacturer")
      brand = node_text(brand_node) if brand_node

      pn_node = listing.at_css(".listing-final-partnumber")
      if pn_node
        text = node_text(pn_node)
        part_number = text unless text.empty?
      end

      price_node = listing.at_css(".listing-price") || listing.at_css('[id^="dprice"]')
      if price_node
        match = node_text(price_node).match(/([A-Za-z]{2,3})?\$([0-9,]+\.?[0-9]*)/)
        price = match[1] ? "#{match[1]}$#{match[2]}" : "$#{match[2]}" if match
      end

      image_node = listing.at_css("img.listing-inline-image, img[id^='inlineimg_thumb']")
      image_url = format_url(image_node["src"]) if image_node && image_node["src"]

      info_link = listing.at_css("a[href*='moreinfo.php']")
      info_url = format_url(info_link["href"]) if info_link && info_link["href"]

      part_name = name
      if part_name.nil?
        footnote = listing.at_css(".listing-footnote-text")
        part_name =
          if footnote
            text = node_text(footnote).sub(/\ACategory:\s*/i, "").strip
            text.empty? ? "Unknown Part" : text
          else
            "Unknown Part"
          end
      end

      return nil if part_number == "Unknown" && price.nil? && brand.nil?

      PartInfo.new(
        name: part_name,
        part_number: part_number,
        price: price,
        brand: brand,
        url: info_url,
        image_url: image_url,
        info_url: info_url
      )
    rescue StandardError
      nil
    end

    def extract_video_url(page_text, soup)
      VIDEO_PATTERNS.each do |pattern|
        match = page_text.match(pattern)
        next unless match

        source = pattern.source
        if source.include?("youtube") || source.include?("youtu.be")
          return "https://www.youtube.com/watch?v=#{match[1]}"
        elsif source.include?("vimeo")
          return "https://vimeo.com/#{match[1]}"
        else
          return match[0]
        end
      end

      soup.css("video, iframe").each do |video|
        src = video["src"] || ""
        next if src.empty?

        if [".mp4", ".webm", ".mov", "youtube", "vimeo"].any? { |ext| src.include?(ext) }
          return src.start_with?("http") ? src : "https://www.rockauto.com#{src}"
        end
      end

      nil
    rescue StandardError
      nil
    end

    def clean_name_for(text, price, part_number, brand)
      clean = text.dup
      clean = clean.gsub(/\$[0-9,]+\.?[0-9]*/, "") if price
      clean = clean.gsub(/#{Regexp.escape(part_number)}/i, "") if part_number != "Unknown"
      clean = clean.gsub(/#{Regexp.escape(brand)}/i, "") if brand

      clean = clean.gsub(/\s+/, " ").strip
      clean.gsub(/[-:.,]+\z/, "").strip
    end

    def clean_part_name(name, brand, part_number)
      clean = name.dup
      clean = clean.gsub(brand, "") if brand
      clean = clean.gsub(part_number, "") if part_number != "Unknown"

      NOISE_PATTERNS.each { |noise| clean = clean.gsub(noise, "") }

      clean.strip
    end

    def format_url(href)
      return nil if href.nil? || href.empty?

      if href.start_with?("http")
        href
      elsif href.start_with?("/")
        "https://www.rockauto.com#{href}"
      else
        "https://www.rockauto.com/#{href}"
      end
    end

    def extract_urls_from_row(row, info)
      row.css("a[href]").each do |link|
        href = link["href"] || ""
        if href.include?("catalog") && !href.include?("moreinfo")
          info[:url] = format_url(href)
          break
        end
      end

      img = row.at_css("img")
      if img
        src = img["src"] || ""
        if !src.empty? && !src.include?("flag_") && !src.include?("loading.gif")
          info[:image_url] = format_url(src)
        end
      end

      info_link = row.at_css("a[href*='moreinfo.php'], a[href*='details'], a[href*='info']")
      if info_link
        href = info_link["href"] || ""
        info[:info_url] = format_url(href) unless href.empty?
      end
    end

    # Nokogiri helper: collapse whitespace and strip.
    def node_text(node)
      return "" if node.nil?

      node.text.gsub(/\s+/, " ").strip
    end

    def titlecase(value)
      value.to_s.downcase.gsub(/\b\w/) { |c| c.upcase }
    end
  end
end
