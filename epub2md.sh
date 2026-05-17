#!/bin/bash
# epub2md.sh - 将 epub 转换为 Notion 兼容的干净 Markdown
# 用法: ./epub2md.sh [--split] [--split-level N] <input.epub> [output.md]
#
# 处理流程概览：
# 1. 用临时 Lua filter 让 pandoc 在转换时尽量保留语义化样式和图片。
# 2. 从 EPUB 的 ncx 目录读取书名、章节标题和目录深度，作为标题恢复和拆分的唯一权威来源。
# 3. 对 pandoc 生成的 Markdown 做有限清理：去掉残留 HTML、恢复标题层级、规范段落空行。
# 4. 可选按章节拆分，并把 Markdown 和图片目录打包成 Notion 更容易导入的 zip。

set -Eeuo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
if [ ! -t 2 ]; then GREEN='' YELLOW='' RED='' NC=''; fi

log() { printf '%b\n' "$*" >&2; }
die() { printf "${RED}错误: %s${NC}\n" "$*" >&2; exit 1; }

show_usage() {
  cat <<EOF
用法: $0 [选项] <input.epub> [output.md]

选项:
  --split             将不同章节拆分成多个 Markdown 文件，放入 <输出名>-notion/ 目录
  --split-level N     指定拆分标题层级，范围 1-6，默认 2
  -h, --help          显示帮助信息

示例:
  $0 book.epub book.md
  $0 --split book.epub book.md
  $0 --split --split-level 1 book.epub book.md
EOF
}

LUA_FILTER="" TITLE_MAP=""
# 临时文件只在本次转换中使用。脚本中间失败时也要清理，避免 /tmp 堆积旧 filter/map。
cleanup() {
  if [ -n "$LUA_FILTER" ] && [ -f "$LUA_FILTER" ]; then
    rm -f "$LUA_FILTER"
  fi
  if [ -n "$TITLE_MAP" ] && [ -f "$TITLE_MAP" ]; then
    rm -f "$TITLE_MAP"
  fi
  return 0
}
trap cleanup EXIT

SPLIT=0
SPLIT_LEVEL=2
POSITIONAL=()
# 参数解析保持纯 Bash，避免依赖 getopt 在 macOS/Linux 之间的差异。
while [ $# -gt 0 ]; do
  case "$1" in
    --split)
      SPLIT=1
      shift
      ;;
    --split-level)
      [ $# -ge 2 ] || die "--split-level 需要指定 1-6 的层级"
      SPLIT_LEVEL="$2"
      shift 2
      ;;
    --split-level=*)
      SPLIT_LEVEL="${1#*=}"
      shift
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        POSITIONAL+=("$1")
        shift
      done
      ;;
    -*)
      die "未知参数: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ "${#POSITIONAL[@]}" -lt 1 ] || [ "${#POSITIONAL[@]}" -gt 2 ]; then
  show_usage >&2
  exit 1
fi

[[ "$SPLIT_LEVEL" =~ ^[1-6]$ ]] || die "--split-level 必须是 1-6"

INPUT="${POSITIONAL[0]}"
[ -f "$INPUT" ] || die "文件不存在: $INPUT"
command -v pandoc &>/dev/null || die "需要安装 pandoc (brew install pandoc)"
command -v perl &>/dev/null || die "需要安装 perl"

BASENAME=$(basename "$INPUT" .epub)
if [ "${#POSITIONAL[@]}" -ge 2 ]; then
  OUTPUT="${POSITIONAL[1]}"
else
  OUTPUT="${BASENAME}.md"
fi
OUTPUT_DIR=$(dirname "$OUTPUT")
OUTPUT_NAME=$(basename "$OUTPUT" .md)
MEDIA_DIR="${OUTPUT_DIR}/${OUTPUT_NAME}-media"
MEDIA_BASENAME=$(basename "$MEDIA_DIR")
SPLIT_DIR="${OUTPUT_DIR}/${OUTPUT_NAME}-notion"
SPLIT_COUNT=0
ZIP_OUTPUT=""
[ -d "$OUTPUT_DIR" ] || mkdir -p "$OUTPUT_DIR"

TOTAL_STEPS=6
[ "$SPLIT" -eq 1 ] && TOTAL_STEPS=7

log "${GREEN}[1/${TOTAL_STEPS}]${NC} 创建 Lua 过滤器..."

LUA_FILTER=$(mktemp /tmp/epub-clean-XXXXXX.lua)
cat > "$LUA_FILTER" << 'LUAEOF'
-- 这个 filter 只做轻量语义归一化：
-- - 将 EPUB/CSS 中常见的 bold/italic class 转成 Markdown 可表达的 Strong/Emph。
-- - 删除页码、分页符、calibre TOC 这类导入 Notion 时没有价值的噪声。
-- - 把 raw HTML 里的 img 尽量转成 pandoc Image，交给 --extract-media 管理图片。
function Span(el)
  if el.classes:includes("bold") or el.classes:includes("strong") then
    return pandoc.Strong(el.content)
  end
  if el.classes:includes("italic") or el.classes:includes("emphasis")
     or el.classes:includes("em") then
    return pandoc.Emph(el.content)
  end
  if el.classes:includes("pagebreak") or el.classes:includes("pagenum")
     or el.classes:includes("koboSpan") then
    return {}
  end
  return el.content
end
function Div(el)
  if el.classes:includes("quote") or el.classes:includes("blockquote")
     or el.classes:includes("epigraph") then
    return pandoc.BlockQuote(el.content)
  end
  if el.classes:includes("pagebreak") or el.classes:includes("mbp_pagebreak")
     or el.classes:includes("calibreToc") then
    return {}
  end
  return el.content
end
function RawBlock(el)
  if el.format == "html" then
    local src = el.text:match('[Ss][Rr][Cc]=["\']([^"\']+)["\']')
    if src then
      local alt = el.text:match('[Aa][Ll][Tt]=["\']([^"\']*)["\']') or ""
      return pandoc.Para({pandoc.Image({pandoc.Str(alt)}, src)})
    end
    return {}
  end
  return el
end
function RawInline(el)
  if el.format == "html" then
    local src = el.text:match('[Ss][Rr][Cc]=["\']([^"\']+)["\']')
    if src then
      local alt = el.text:match('[Aa][Ll][Tt]=["\']([^"\']*)["\']') or ""
      return pandoc.Image({pandoc.Str(alt)}, src)
    end
    return {}
  end
  return el
end
function Link(el)
  -- EPUB 内部章节锚点在拆成 Markdown 后通常失效；保留文字比保留坏链接更适合导入 Notion。
  if el.target:match("%.x?html") or el.target:match("^#") then
    return el.content
  end
  return el
end
LUAEOF

log "${GREEN}[2/${TOTAL_STEPS}]${NC} 解析 EPUB 目录结构..."

find_toc_content() {
  # EPUB 的目录文件通常由 OPF manifest 指向，但不同制作工具的路径不一致。
  # 优先通过 META-INF/container.xml 找 OPF，再从 OPF 找 ncx；找不到时尝试常见兜底路径。
  local epub="$1" opf_path opf_dir toc_href
  opf_path=$(unzip -p "$epub" META-INF/container.xml 2>/dev/null | \
    perl -ne 'print "$1\n" if /full-path="([^"]+)"/' | head -n1)
  if [ -n "$opf_path" ]; then
    opf_dir=$(dirname "$opf_path"); [ "$opf_dir" = "." ] && opf_dir=""
    toc_href=$(unzip -p "$epub" "$opf_path" 2>/dev/null | \
      perl -ne 'print "$1\n" if /href="([^"]*\.ncx)"/' | head -n1)
    if [ -n "$toc_href" ]; then
      local p; [ -n "$opf_dir" ] && p="${opf_dir}/${toc_href}" || p="$toc_href"
      unzip -p "$epub" "$p" 2>/dev/null && return 0
    fi
  fi
  unzip -p "$epub" toc.ncx 2>/dev/null && return 0
  unzip -p "$epub" OEBPS/toc.ncx 2>/dev/null && return 0
  return 1
}

normalize_media_links() {
  # pandoc 提取图片后会根据 EPUB 内部路径生成链接；导入 Notion 的 split 目录时，
  # 统一改成 ./<media-dir>/...，保证主文件和拆分文件都能相对引用图片。
  local file="$1"
  local media_base="$2"
  MEDIA_BASENAME_ENV="$media_base" perl -i -pe '
    BEGIN { $media = $ENV{MEDIA_BASENAME_ENV}; }
    s{!\[([^\]]*)\]\((?:\./)*(?:[^)\n]*/)?\Q$media\E/([^)\n]*)\)}{![$1](./$media/$2)}g;
  ' "$file"
}

split_markdown_file() {
  # 拆分策略：
  # - 有 EPUB TOC 时，以 TOC navPoint 顺序和深度为准，避免用“第X章/上篇”等正则误判前置章节。
  # - 无 TOC 或 TOC 标题无法匹配时，退回旧的 Markdown 标题启发式拆分。
  # - 第一条 TOC 前的封面/标题页内容用书名写成 00-*.md。
  local source="$1"
  local target_dir="$2"
  local media_base="$3"
  local level="$4"
  local title_map="$5"
  local fallback_title="$6"

  SPLIT_SOURCE="$source" SPLIT_TARGET_DIR="$target_dir" \
  SPLIT_MEDIA_BASENAME="$media_base" SPLIT_LEVEL="$level" \
  SPLIT_TITLE_MAP="$title_map" SPLIT_FALLBACK_TITLE="$fallback_title" perl <<'PERLEOF'
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));
use Encode qw(decode FB_CROAK);
use File::Spec;

# 环境变量进入 Perl 时仍是字节串；先按 UTF-8 解码，避免和章节标题拼接后路径变成 mojibake。
sub env_utf8 {
  my ($name) = @_;
  return "" if !defined $ENV{$name};
  return decode("UTF-8", $ENV{$name}, FB_CROAK);
}

my $source = env_utf8("SPLIT_SOURCE");
my $target_dir = env_utf8("SPLIT_TARGET_DIR");
my $media_base = env_utf8("SPLIT_MEDIA_BASENAME");
my $title_map = env_utf8("SPLIT_TITLE_MAP");
my $fallback_title = env_utf8("SPLIT_FALLBACK_TITLE");
my $split_level = $ENV{SPLIT_LEVEL};

open my $in, "<:encoding(UTF-8)", $source or die "无法读取 $source: $!";
my @lines = <$in>;
close $in;
chomp @lines;

my %used_names;
my @created_files;
my @front_lines;
my @current_lines;
my $current_title = "";
my $page_index = 0;

sub reset_state {
  %used_names = ();
  @created_files = ();
  @front_lines = ();
  @current_lines = ();
  $current_title = "";
  $page_index = 0;
}

sub normalize_title {
  my ($title) = @_;
  $title =~ s/\r//g;
  $title =~ s/^\s+|\s+$//g;
  $title =~ s/^#{1,6}\s+//;
  $title =~ s/^\*\*(.+)\*\*$/$1/;
  $title =~ s/^`(.+)`$/$1/;
  $title =~ s/\[([^\]]+)\]\([^)]+\)/$1/g;
  $title =~ s/\x{00a0}/ /g;
  $title =~ s/\s+/ /g;
  return $title;
}

sub clean_title {
  my ($title) = @_;
  $title = normalize_title($title);
  $title =~ s/[\/\\:*?"<>|]/_/g;
  $title =~ s/[\x00-\x1f]//g;
  $title = "未命名" if $title eq "";
  return substr($title, 0, 80);
}

sub unique_path {
  my ($index, $title) = @_;
  my $base = sprintf("%02d-%s", $index, clean_title($title));
  my $name = "$base.md";
  my $serial = 2;
  while ($used_names{$name}) {
    $name = "$base-$serial.md";
    $serial++;
  }
  $used_names{$name} = 1;
  return File::Spec->catfile($target_dir, $name);
}

sub write_page {
  my ($title, $lines_ref, $fixed_index) = @_;
  my @page_lines = @$lines_ref;
  shift @page_lines while @page_lines && $page_lines[0] =~ /^\s*$/;
  pop @page_lines while @page_lines && $page_lines[-1] =~ /^\s*$/;
  return if !@page_lines;

  my $index = defined $fixed_index ? $fixed_index : ++$page_index;
  my $path = unique_path($index, $title);
  open my $out, ">:encoding(UTF-8)", $path or die "无法写入 $path: $!";
  print {$out} join("\n", @page_lines), "\n";
  close $out;
  push @created_files, $path;
}

my $book_title = $fallback_title ne "" ? $fallback_title : "全文";
my @toc_entries;
if ($title_map ne "" && -s $title_map) {
  open my $map, "<:encoding(UTF-8)", $title_map or die "无法读取 $title_map: $!";
  while (my $line = <$map>) {
    chomp $line;
    my ($kind, $depth, $title) = split /\t/, $line, 4;
    next if !defined $kind || !defined $title || $title eq "";
    if ($kind eq "book") {
      $book_title = $title;
      next;
    }
    next if $kind ne "nav" || !defined $depth || $depth !~ /^\d+$/;
    next if $depth > $split_level;
    push @toc_entries, {
      title => $title,
      key => normalize_title($title),
    };
  }
  close $map;
}

sub find_next_toc_match {
  my ($key, $start_index, $entries_ref) = @_;
  for (my $i = $start_index; $i < @$entries_ref; $i++) {
    return $i if $entries_ref->[$i]->{key} eq $key;
  }
  return -1;
}

sub split_by_toc {
  return 0 if !@toc_entries;

  reset_state();
  my $matched = 0;
  my $toc_index = 0;

  for my $line (@lines) {
    if ($line =~ /^(#{1,6})\s+(.+?)\s*$/) {
      my $title = $2;
      my $match_index = find_next_toc_match(normalize_title($title), $toc_index, \@toc_entries);
      if ($match_index >= 0) {
        if ($matched == 0) {
          write_page($book_title, \@front_lines, 0);
          @front_lines = ();
        } else {
          write_page($current_title, \@current_lines, undef);
          @current_lines = ();
        }
        $matched++;
        $toc_index = $match_index + 1;
        $current_title = $toc_entries[$match_index]->{title};
        @current_lines = ($line);
        next;
      }
    }

    if ($matched) {
      push @current_lines, $line;
    } else {
      push @front_lines, $line;
    }
  }

  return 0 if !$matched;
  write_page($current_title, \@current_lines, undef);
  return 1;
}

sub flush_front_fallback {
  return if !@front_lines;
  my $title = @created_files ? "后置内容" : "前置内容";
  my $index = @created_files ? undef : 0;
  write_page($title, \@front_lines, $index);
  @front_lines = ();
}

sub flush_current {
  return if !@current_lines;
  write_page($current_title, \@current_lines, undef);
  @current_lines = ();
  $current_title = "";
}

sub is_chapter_like {
  my ($title) = @_;
  return $title =~ /^(?:第[[:alnum:]一二三四五六七八九十百千万零〇两]+[章节回](?:\s|$)|Chapter\s+[[:alnum:]]+(?:\s|$))/i;
}

sub is_part_like {
  my ($title) = @_;
  return $title =~ /^(?:上篇|下篇|前篇|后篇|第.+?[部篇卷](?:\s|$)|Part\s+[[:alnum:]]+(?:\s|$))/i;
}

sub split_by_heading_fallback {
  reset_state();
  my $chapter_seen = 0;

  for my $line (@lines) {
    if ($line =~ /^(#{1,6})\s+(.+?)\s*$/) {
      my $heading_level = length($1);
      my $title = $2;
      my $chapter_like = is_chapter_like($title);
      my $part_like = is_part_like($title);
      my $is_split_heading =
        ($heading_level == $split_level && ($chapter_seen || $chapter_like || $part_like))
        || ($heading_level < $split_level && $part_like);

      if ($is_split_heading) {
        flush_front_fallback();
        flush_current();
        $chapter_seen = 1 if $chapter_like || ($heading_level == $split_level && !$part_like && @created_files);
        $current_title = $title;
        @current_lines = ($line);
        next;
      }
    }

    if (@current_lines) {
      push @current_lines, $line;
    } else {
      push @front_lines, $line;
    }
  }

  flush_current();
  if (@front_lines) {
    if (@created_files) {
      write_page("后置内容", \@front_lines, undef);
    } else {
      write_page("全文", \@front_lines, 0);
    }
  }
}

if (!split_by_toc()) {
  split_by_heading_fallback();
}

print scalar(@created_files);
PERLEOF
}

TITLE_MAP=$(mktemp /tmp/epub-titles-XXXXXX.tsv)
TOC_XML=$(find_toc_content "$INPUT" || true)
if [ -n "$TOC_XML" ]; then
  TOC_XML_ENV="$TOC_XML" perl -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    use utf8;
    binmode STDOUT, ":encoding(UTF-8)";

    sub decode_xml_text {
      my ($text) = @_;
      $text =~ s/<!\[CDATA\[(.*?)\]\]>/$1/sg;
      $text =~ s/<[^>]+>//g;
      $text =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/eg;
      $text =~ s/&#([0-9]+);/chr($1)/eg;
      $text =~ s/&lt;/</g;
      $text =~ s/&gt;/>/g;
      $text =~ s/&quot;/"/g;
      $text =~ s/&apos;/chr(39)/eg;
      $text =~ s/&amp;/&/g;
      $text =~ s/\r//g;
      $text =~ s/\t/ /g;
      $text =~ s/^\s+|\s+$//g;
      $text =~ s/\s+/ /g;
      return $text;
    }

    my $xml = decode("UTF-8", $ENV{TOC_XML_ENV}, FB_CROAK);
    if ($xml =~ m{<docTitle\b[^>]*>.*?<text\b[^>]*>(.*?)</text>.*?</docTitle>}is) {
      my $book_title = decode_xml_text($1);
      print "book\t0\t$book_title\t\n" if $book_title ne "";
    }

    my $depth = 0;
    my @stack;
    sub emit_nav {
      my ($entry) = @_;
      return if !$entry || $entry->{emitted} || !defined $entry->{title} || $entry->{title} eq "";
      my $href = defined $entry->{href} ? $entry->{href} : "";
      $href =~ s/\t/ /g;
      print "nav\t$entry->{depth}\t$entry->{title}\t$href\n";
      $entry->{emitted} = 1;
    }

    while ($xml =~ m{(<navPoint\b[^>]*>|</navPoint>|<text\b[^>]*>.*?</text>|<content\b[^>]*>)}gis) {
      my $token = $1;
      if ($token =~ /^<navPoint\b/i) {
        $depth++;
        $stack[$depth] = { depth => $depth, emitted => 0 };
        next;
      }
      if ($token =~ m{^</navPoint}i) {
        emit_nav($stack[$depth]);
        delete $stack[$depth];
        $depth-- if $depth > 0;
        next;
      }
      next if $depth < 1;
      my $entry = $stack[$depth];
      if ($token =~ m{^<text\b[^>]*>(.*?)</text>}is && !defined $entry->{title}) {
        $entry->{title} = decode_xml_text($1);
      } elsif ($token =~ /^<content\b[^>]*\bsrc=["\x27]([^"\x27]+)["\x27]/i) {
        $entry->{href} = decode_xml_text($1);
        emit_nav($entry);
      }
    }
  ' > "$TITLE_MAP"
  NAV_COUNT=$(perl -F'\t' -alne '$n++ if $F[0] eq "nav"; END { print $n // 0 }' "$TITLE_MAP")
  log "  找到 ${NAV_COUNT} 个章节标题"
else
  log "${YELLOW}  警告: 未找到目录，标题层级无法恢复${NC}"
fi

log "${GREEN}[3/${TOTAL_STEPS}]${NC} pandoc 转换..."
pandoc "$INPUT" -f epub -t gfm+pipe_tables \
  --lua-filter="$LUA_FILTER" --extract-media="$MEDIA_DIR" \
  --wrap=none --markdown-headings=atx -o "$OUTPUT"

log "${GREEN}[4/${TOTAL_STEPS}]${NC} 清理残留 HTML（跳过代码块）..."
perl -i -pe '
  if (/^(?:```|~~~)/) { $in_code = !$in_code }
  if (!$in_code) {
    s/<img\s+src="([^"]+)"[^>]*\/?>/![]($1)/gi;
    s/<\/?sup[^>]*>//gi; s/<\/?sub[^>]*>//gi;
    s/<!--.*?-->//g; s/<br\s*\/?>/\n/gi;
    s/<\/?(?:span|div|center|small|u)[^>]*>//gi;
    s/^·\s?/- /;
    s/^(\d+)\.([^\s\d])/$1. $2/;
    s/^\s*$//;
  }
' "$OUTPUT"

log "${GREEN}[5/${TOTAL_STEPS}]${NC} 恢复标题层级..."

# 清除末尾 TOC 块（检测文件最后 50 行内的 Table of Contents 并删除至末尾）
perl -i -0777 -pe '
  if (/^.*\*?\*?Table of Contents\*?\*?\s*\n/m) {
    my $pos = $-[0];
    my $before = substr($_, 0, $pos);
    my $after = substr($_, $pos);
    my @lines = split /\n/, $before;
    if (length($after) < length($_) * 0.1) {
      $_ = $before;
    }
  }
' "$OUTPUT"

if [ -s "$TITLE_MAP" ]; then
  TITLE_MAP_PATH="$TITLE_MAP" perl -i -0pe '
    BEGIN{
      sub normalize_title {
        my ($title) = @_;
        $title =~ s/\r//g;
        $title =~ s/^\s+|\s+$//g;
        $title =~ s/^#{1,6}\s+//;
        $title =~ s/^\*\*(.+)\*\*$/$1/;
        $title =~ s/^`(.+)`$/$1/;
        $title =~ s/\[([^\]]+)\]\([^)]+\)/$1/g;
        $title =~ s/\xC2\xA0/ /g;
        $title =~ s/\s+/ /g;
        return $title;
      }
      open my $f,"<",$ENV{TITLE_MAP_PATH} or die;
      {
        local $/ = "\n";
        while(my $map_line=<$f>){chomp $map_line;my($kind,$depth,$title)=split/\t/,$map_line,4;next unless defined $title && $title ne "";
          next unless $kind eq "nav" && defined $depth && $depth =~ /^\d+$/;
          $depth = 6 if $depth > 6;
          $depth = 1 if $depth < 1;
          my $key = normalize_title($title);
          next if $key eq "";
          $m{$key}=$depth unless exists $m{$key};
          $canonical{$key}=$title unless exists $canonical{$key};
        }
      }
    }
    my @lines = split /\n/, $_, -1;
    my @out;
    my $in_code = 0;
    for (my $i = 0; $i < @lines; $i++) {
      my $line = $lines[$i];
      my $is_fence = $line =~ /^(?:```|~~~)/;
      if (!$in_code) {
        my $plain = normalize_title($line);
        if (exists $m{$plain}) {
          push @out, ("#" x $m{$plain}) . " " . $canonical{$plain};
          next;
        }
        if ($plain ne "" && $i + 1 < @lines) {
          my $next = $lines[$i + 1];
          my $next_plain = normalize_title($next);
          my $combined = "$plain $next_plain";
          if ($next_plain ne "" && exists $m{$combined}) {
            push @out, ("#" x $m{$combined}) . " " . $canonical{$combined};
            $i++;
            next;
          }
        }
      }
      push @out, $line;
      $in_code = !$in_code if $is_fence;
    }
    $_ = join "\n", @out;
  ' "$OUTPUT"
fi

log "${GREEN}[6/${TOTAL_STEPS}]${NC} 最终清理..."
perl -i -0pe '
  sub is_blank_line {
    my ($line) = @_;
    (my $x = $line) =~ s/\xC2\xA0/ /g;
    return $x !~ /\S/;
  }
  sub is_fence_line { return $_[0] =~ /^\s{0,3}(?:```|~~~)/; }
  sub is_heading_line { return $_[0] =~ /^\s{0,3}#{1,6}\s+\S/; }
  sub is_image_line { return $_[0] =~ /^\s*!\[[^\]]*\]\([^)]+\)\s*$/; }
  sub is_hr_line { return $_[0] =~ /^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/; }
  sub is_list_item_line { return $_[0] =~ /^(?:[-+*]\s+|\d+[.)]\s+)/; }
  sub is_list_child_line { return $_[0] =~ /^[ \t]+\S/; }
  sub is_table_line {
    return $_[0] =~ /^\s*\|.*\|\s*$/
      || $_[0] =~ /^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/;
  }
  sub is_quote_line { return $_[0] =~ /^\s{0,3}>\s?/; }
  sub block_type {
    my ($line) = @_;
    return "heading" if is_heading_line($line);
    return "image" if is_image_line($line);
    return "hr" if is_hr_line($line);
    return "list" if is_list_item_line($line);
    return "child" if is_list_child_line($line);
    return "table" if is_table_line($line);
    return "quote" if is_quote_line($line);
    return "para";
  }
  sub needs_block_gap {
    my ($prev, $curr) = @_;
    return 0 if !$prev || !$curr;
    return 0 if ($prev eq "list" || $prev eq "child") && ($curr eq "list" || $curr eq "child");
    return 0 if $prev eq "table" && $curr eq "table";
    return 0 if $prev eq "quote" && $curr eq "quote";
    return 1;
  }

  my @lines = split /\n/, $_, -1;
  my @out;
  my $in_code = 0;
  my $pending_blank = 0;
  my $last_type = "";

  for my $line (@lines) {
    if ($in_code) {
      push @out, $line;
      if (is_fence_line($line)) {
        $in_code = 0;
        $last_type = "code";
      }
      next;
    }

    if (is_blank_line($line)) {
      $pending_blank = 1 if @out;
      next;
    }

    my $is_fence = is_fence_line($line);
    my $curr_type = $is_fence ? "code" : block_type($line);
    if (@out && $out[-1] ne "" && ($pending_blank || needs_block_gap($last_type, $curr_type))) {
      push @out, "";
    }
    push @out, $line;
    $pending_blank = 0;
    $last_type = $curr_type;
    $in_code = 1 if $is_fence;
  }
  pop @out while @out && $out[-1] eq "";
  $_ = join "\n", @out;
  $_ .= "\n" if $_ ne "";
' "$OUTPUT"

normalize_media_links "$OUTPUT" "$MEDIA_BASENAME"

if [ "$SPLIT" -eq 1 ]; then
  log "${GREEN}[7/${TOTAL_STEPS}]${NC} 拆分章节 Markdown..."
  rm -rf "$SPLIT_DIR"
  mkdir -p "$SPLIT_DIR"
  if [ -d "$MEDIA_DIR" ]; then
    cp -R "$MEDIA_DIR" "$SPLIT_DIR/"
  fi
  SPLIT_COUNT=$(split_markdown_file "$OUTPUT" "$SPLIT_DIR" "$MEDIA_BASENAME" "$SPLIT_LEVEL" "$TITLE_MAP" "$OUTPUT_NAME")
  log "  拆分输出: $SPLIT_DIR/ ($SPLIT_COUNT 个 Markdown)"
fi

LINES=$(wc -l < "$OUTPUT")
if [ -d "$MEDIA_DIR" ]; then
  IMGS=$(find "$MEDIA_DIR" -type f | wc -l | tr -d ' ')
else
  IMGS=0
fi
# 统计残留 HTML（跳过代码块）
HTML_N=$(perl -ne '
  if (/^(?:```|~~~)/) { $c = !$c }
  $n++ if !$c && /<[a-zA-Z][^>]*>/;
  END { print $n // 0 }
' "$OUTPUT")

# 生成 Notion 导入 zip 包（markdown + 图片一起打包）
if [ "$SPLIT" -eq 1 ] && command -v zip &>/dev/null && [ -d "$SPLIT_DIR" ]; then
  ZIP_OUTPUT="${OUTPUT_DIR}/${OUTPUT_NAME}-notion.zip"
  rm -f "$ZIP_OUTPUT"
  (cd "$SPLIT_DIR" && zip -qr "../$(basename "$ZIP_OUTPUT")" .)
  log "  Notion 导入包: $ZIP_OUTPUT"
elif command -v zip &>/dev/null && [ -d "$MEDIA_DIR" ] && [ "$IMGS" -gt 0 ]; then
  ZIP_OUTPUT="${OUTPUT_DIR}/${OUTPUT_NAME}-notion.zip"
  rm -f "$ZIP_OUTPUT"
  (cd "$OUTPUT_DIR" && zip -qr "$(basename "$ZIP_OUTPUT")" \
    "$(basename "$OUTPUT")" "$(basename "$MEDIA_DIR")")
  log "  Notion 导入包: $ZIP_OUTPUT"
fi

echo ""
log "${GREEN}转换完成!${NC}"
log "  输出: $OUTPUT ($LINES 行)"
[ "$SPLIT" -eq 1 ] && log "  章节: $SPLIT_DIR/ ($SPLIT_COUNT 个 Markdown)"
log "  图片: $MEDIA_DIR/ ($IMGS 张)"
[ "$HTML_N" -gt 0 ] && log "${YELLOW}  警告: 残留 $HTML_N 处 HTML 标签${NC}"
echo ""
if [ -n "$ZIP_OUTPUT" ] && [ -f "$ZIP_OUTPUT" ]; then
  log "${GREEN}建议:${NC} 直接将 ${OUTPUT_NAME}-notion.zip 导入 Notion（含图片）"
  if [ "$SPLIT" -eq 1 ]; then
    log "  如图片未显示，再手动上传 $SPLIT_DIR/$MEDIA_BASENAME/ 目录"
  else
    log "  如图片未显示，再手动上传 $MEDIA_DIR/ 目录"
  fi
elif [ "$SPLIT" -eq 1 ]; then
  log "${YELLOW}提示:${NC} 可将 $SPLIT_DIR/ 目录压缩后导入 Notion"
else
  log "${YELLOW}提示:${NC} 可将 .md 和 media 目录一起压缩后导入 Notion"
fi
