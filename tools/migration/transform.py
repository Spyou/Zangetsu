import json


def mylist_row(doc):
    """Transform Appwrite MyList document to Supabase row."""
    cover_headers = None
    if "coverHeaders" in doc:
        try:
            cover_headers = json.loads(doc["coverHeaders"])
        except (json.JSONDecodeError, TypeError):
            cover_headers = None

    return {
        "user_key": doc["userId"],
        "source_id": doc["sourceId"],
        "item_id": doc["itemId"],
        "title": doc["title"],
        "cover": doc["cover"],
        "cover_headers": cover_headers,
        "url": doc["url"],
        "type": doc["type"],
        "added_at": doc["addedAt"],
    }


def history_row(doc):
    """Transform Appwrite History document to Supabase row."""
    return {
        "user_key": doc["userId"],
        "source_id": doc["sourceId"],
        "show_id": doc["showId"],
        "show_title": doc["showTitle"],
        "position_ms": doc["position"],
        "duration_ms": doc["duration"],
        "updated_at": doc["updatedAt"],
        "episode_number": doc["episodeNumber"],
    }


def backup_row(doc):
    """Transform Appwrite Backup document to Supabase row."""
    return {
        "user_key": doc["userId"],
        "payload": doc["payload"],
        "updated_at": doc["updatedAt"],
    }
