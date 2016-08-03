require 'open3'

module SmarterCSV

  class HeaderSizeMismatch < StandardError; end
  class HeadersNotProvided < StandardError; end
  class IncorrectOption    < StandardError; end

  def self.process(input, opts = {}, &block)   # first parameter: filename or input object with readline method
    opts = {
      chunk_size: nil,
      col_sep: ',',
      comment_regexp: /^#/,
      convert_values_to_numeric: true,
      downcase_header: true,
      file_encoding: 'utf-8',
      force_simple_split: false,
      headers_in_file: true,
      keep_original_headers: false,
      key_mapping: nil,
      quote_char: '"',
      remove_empty_hashes: true,
      remove_empty_values: true,
      remove_unmapped_keys: false,
      remove_values_matching: nil,
      remove_zero_values: false,
      row_sep: "\n",
      sanitize_chars_in_headers: /[\s=-]+/,
      strings_as_keys: false,
      strip_chars_from_headers: nil,
      strip_whitespace: true,
      user_provided_headers: nil,
      value_converters: nil,
      verbose: false
    }.merge(opts)

    filehandle = input.respond_to?(:readline) ? input : File.open(input, "r:#{opts[:file_encoding]}")
    filehandle = normalize_file(filehandle)

    if opts[:row_sep] == :auto
      puts "DEPRECATION [smarter_csv]: argument usage :row_sep => :auto is depecated. File is normalized to all new lines to be a \"\\n\" before processing now."
      opts[:row_sep] = "\n"
    end

    opts[:csv_options] = opts.select{|k,v| [:col_sep, :row_sep, :quote_char].include?(k)} # opts.slice(:col_sep, :row_sep, :quote_char)

    result = []
    line_count = 0

    headers = get_headers(filehandle, opts)
    line_count += 1 if opts[:headers_in_file]

    # in case we use chunking.. we'll need to set it up..
    if ! opts[:chunk_size].nil? && opts[:chunk_size].to_i > 0
      use_chunks = true
      chunk_size = opts[:chunk_size].to_i
      chunk_count = 0
      chunk = []
    else
      use_chunks = false
    end

    until filehandle.eof?
      line = filehandle.readline(opts[:row_sep])
      line_count += 1

      puts "processing line %10d\r" % line_count if opts[:verbose]

      line.scrub! # Regexp match blows up with various UTF-8 characters.
      next if line =~ opts[:comment_regexp]  # ignore all comment lines if there are any

      # cater for the quoted csv data containing the row separator carriage return character
      # in which case the row data will be split across multiple lines (see the sample content in spec/fixtures/carriage_returns_rn.csv)
      # by detecting the existence of an uneven number of quote characters

      while line.scan(opts[:quote_char]).size % 2 == 1
        puts "line contains uneven number of quote chars so including content of next line" if opts[:verbose]

        filehandle.each_char do |char|
          line += char
          last_char = line[-1]
          break if last_char == opts[:quote_char]
        end

        line += filehandle.readline opts[:row_sep] unless filehandle.eof?
        line.scrub!
      end

      line.chomp!(opts[:row_sep])

      data = nil

      if line[opts[:quote_char]] && !opts[:force_simple_split]
        begin
          data = CSV.parse(line, opts[:csv_options]).flatten.map(&:to_s)
        rescue CSV::MalformedCSVError => e
          raise $!, "#{$!} [SmarterCSV: line #{line_count}]", $!.backtrace
        end
      else
        data = line.split(opts[:col_sep])
      end

      data.map!{ |x| x.gsub(opts[:quote_char],'') }
      data.map!{ |x| x.strip }  if opts[:strip_whitespace]

      hash = Hash.zip(headers, data)  # from Facets of Ruby library

      # make sure we delete any key/value pairs from the hash, which the user wanted to delete:
      hash.delete(nil)
      hash.delete('');
      hash.delete(:"")

      # remove empty values using the same regexp as used by the rails blank? method
      # which caters for double \n and \r\n characters such as "1\r\n\r\n2" whereas the original check (v =~ /^\s*$/) does not
      hash.delete_if{|k,v| v.nil? || v !~ /[^[:space:]]/}  if opts[:remove_empty_values]

      hash.delete_if{|k,v| !v.nil? && v[/^(\d+|\d+\.\d+)$/] && v.to_f == 0} if opts[:remove_zero_values]   # values are typically Strings!
      hash.delete_if{|k,v| v =~ opts[:remove_values_matching]} if opts[:remove_values_matching]

      if opts[:convert_values_to_numeric]
        hash.each do |k,v|
          # deal with the :only / :except opts to :convert_values_to_numeric
          next if SmarterCSV.only_or_except_limit_execution( opts, :convert_values_to_numeric , k )

          # convert if it's a numeric value:
          case v
          when /^[+-]?\d+\.\d+$/
            hash[k] = v.to_f
          when /^[+-]?\d+$/
            hash[k] = v.to_i
          end
        end
      end

      if opts[:value_converters]
        hash.each do |k,v|
          converter = opts[:value_converters][k]
          next unless converter
          hash[k] = converter.convert(v)
        end
      end

      next if hash.empty? if opts[:remove_empty_hashes]

      if use_chunks
        chunk << hash  # append temp result to chunk

        if chunk.size >= chunk_size || filehandle.eof?   # if chunk if full, or EOF reached
          # do something with the chunk
          if block_given?
            yield chunk  # do something with the hashes in the chunk in the block
          else
            result << chunk  # not sure yet, why anybody would want to do this without a block
          end
          chunk_count += 1
          chunk = []  # initialize for next chunk of data
        else

          # the last chunk may contain partial data, which also needs to be returned (BUG / ISSUE-18)

        end

        # while a chunk is being filled up we don't need to do anything else here

      else # no chunk handling
        if block_given?
          yield [hash]  # do something with the hash in the block (better to use chunking here)
        else
          result << hash
        end
      end
    end
    # last chunk:
    if ! chunk.nil? && chunk.size > 0
      # do something with the chunk
      if block_given?
        yield chunk  # do something with the hashes in the chunk in the block
      else
        result << chunk  # not sure yet, why anybody would want to do this without a block
      end
      chunk_count += 1
      chunk = []  # initialize for next chunk of data
    end

    if block_given?
      return chunk_count  # when we do processing through a block we only care how many chunks we processed
    else
      return result # returns either an Array of Hashes, or an Array of Arrays of Hashes (if in chunked mode)
    end
  ensure
    filehandle.close
    filehandle.unlink if filehandle.respond_to?(:unlink)
  end

  private
  # acts as a road-block to limit processing when iterating over all k/v pairs of a CSV-hash:

  def self.only_or_except_limit_execution( opts, option_name, key )
    if opts[option_name].is_a?(Hash)
      if opts[option_name].has_key?( :except )
        return true if Array( opts[ option_name ][:except] ).include?(key)
      elsif opts[ option_name ].has_key?(:only)
        return true unless Array( opts[ option_name ][:only] ).include?(key)
      end
    end
    return false
  end

  def self.normalize_file(original_file)
    if original_file.is_a?(StringIO)
      saved_original = Tempfile.new('original_file')
      saved_original.binmode
      saved_original.write(original_file.read)
      original_file = saved_original
    end

    tempfile = Tempfile.new('temp')

    cmd = %Q(perl -pe 's/\\r\\n/\\n/g' < #{original_file.path} | perl -pe 's/\\r/\\n/g' > #{tempfile.path})

    [ cmd ].each_with_index do |cmd, idx|
      out, err, st = Open3.capture3(cmd)
      unless st.success?
        raise RuntimeError, "ERROR [smarter_csv]: failure executing '#{cmd}' command, output: #{err}"
      end
    end

    if saved_original
      saved_original.close
      saved_original.unlink
    end

    tempfile.rewind
    tempfile
  end

  def self.get_headers(filehandle, opts)
    headers = get_file_headers(filehandle, opts) if opts[:headers_in_file]

    if headers.nil? && opts[:user_provided_headers].nil?
      raise SmarterCSV::HeadersNotProvided, "ERROR [smarter_csv]: headers are not provided"
    end

    if user_headers = opts[:user_provided_headers]
      if headers && headers.size != user_headers.size
        raise SmarterCSV::HeaderSizeMismatch, "ERROR [smarter_csv]: :user_provided_headers defines #{user_headers.size} headers !=  CSV-file #{filehandle} has #{headers} headers"
      end
      user_headers
    else
      if (map = opts[:key_mapping]).is_a?(Hash)
        headers.map! do |header|
          if map.has_key?(header)
            map[header]
          else
            opts[:remove_unmapped_keys] ? nil : header
          end
        end
      end
      headers
    end
  end

  def self.get_file_headers(filehandle, opts)
    row_sep = opts[:row_sep]

    first_line = filehandle.readline(row_sep).chomp(row_sep)

    # the first line of a CSV file contains the header .. it might be commented out, so we need to read it anyhow
    first_line.sub!(opts[:comment_regexp], '')

    headers = nil

    if first_line[opts[:quote_char]] && !opts[:force_simple_split]
      begin
        headers = CSV.parse(first_line, opts[:csv_options]).flatten.map(&:to_s)
      rescue CSV::MalformedCSVError => e
        raise $!, "#{$!} [SmarterCSV: line 1]", $!.backtrace
      end
    else
      headers = first_line.split(opts[:col_sep])
    end

    if !opts[:keep_original_headers] && !opts[:user_provided_headers]
      headers.map!{ |x| x.gsub(opts[:strip_chars_from_headers], '') } if opts[:strip_chars_from_headers]

      headers = headers
        .map(&:strip)
        .map{ |x| x.gsub(opts[:sanitize_chars_in_headers], '_') }
        .map{ |x| x.gsub(opts[:quote_char], '') }

      headers.map!(&:downcase) if opts[:downcase_header]
      headers.map!(&:to_sym) unless opts[:strings_as_keys]
    end

    puts "Headers from file: #{headers.inspect}" if opts[:verbose]

    headers
  end

end

