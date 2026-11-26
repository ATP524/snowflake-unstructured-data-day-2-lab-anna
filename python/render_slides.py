"""Render each staged slide PDF page to an image for multimodal embeddings.

AI_PARSE_DOCUMENT returns each page's text. Extracting embedded images is
different from rendering the whole page, so this procedure draws every page,
including its layout, charts, and photos, into a PNG. It runs in Snowflake
(sql/10_slide_image_procedure.sql) using pypdfium2 from the Snowflake Anaconda
channel.
"""
import io

SOURCE_STAGE = "@lesson_slides"
IMAGE_STAGE = "@slide_images"
MAX_IMAGE_BYTES = int(4.5 * 1024 * 1024)  # Well under AI_EMBED's 10 MB image limit.
MIN_WIDTH, MAX_WIDTH = 512, 2400


def render_page(page, max_width):
    """Return (bytes, extension, width, height) for one pdfium page."""
    width, _ = page.get_size()
    image = page.render(scale=min(max_width / width, 4.0)).to_pil().convert("RGB")
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    extension = "png"
    if buffer.tell() > MAX_IMAGE_BYTES:
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=85)
        extension = "jpg"
    return buffer.getvalue(), extension, image.width, image.height


def render_slide_images(session, max_width=1600, rebuild=False):
    import pypdfium2 as pdfium

    max_width = int(max_width)
    if not MIN_WIDTH <= max_width <= MAX_WIDTH:
        raise ValueError(f"max_width must be between {MIN_WIDTH} and {MAX_WIDTH}")
    decks = session.sql(
        "SELECT deck_id, stage_path FROM slide_decks ORDER BY lesson_slug"
    ).collect()
    summary = {"decks": len(decks), "decks_rendered": 0, "decks_skipped": 0, "pages": 0}
    for deck_id, stage_path in decks:
        done = session.sql(
            "SELECT COUNT(*) FROM slide_images WHERE deck_id = ?", params=[deck_id]
        ).collect()[0][0]
        if done and not rebuild:
            summary["decks_skipped"] += 1
            continue
        session.sql("DELETE FROM slide_images WHERE deck_id = ?", params=[deck_id]).collect()
        session.sql(f"REMOVE {IMAGE_STAGE}/{deck_id}/").collect()
        pdf_bytes = session.file.get_stream(f"{SOURCE_STAGE}/{stage_path}").read()
        document = pdfium.PdfDocument(pdf_bytes)
        try:
            for page_index in range(len(document)):
                data, extension, width, height = render_page(document[page_index], max_width)
                image_path = f"{deck_id}/page_{page_index + 1:03d}.{extension}"
                session.file.put_stream(
                    io.BytesIO(data), f"{IMAGE_STAGE}/{image_path}",
                    auto_compress=False, overwrite=True,
                )
                session.sql(
                    """INSERT INTO slide_images
                         (slide_id, deck_id, page_index, page_number, image_path,
                          width_px, height_px, image_bytes)
                       SELECT ?, ?, ?, ?, ?, ?, ?, ?""",
                    params=[f"{deck_id}:p{page_index + 1:03d}", deck_id, page_index,
                            page_index + 1, image_path, width, height, len(data)],
                ).collect()
                summary["pages"] += 1
        finally:
            document.close()
        summary["decks_rendered"] += 1
    if summary["decks_rendered"]:
        session.sql("ALTER STAGE slide_images REFRESH").collect()
    return summary
