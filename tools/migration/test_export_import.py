"""Self-check for export_import.py that needs no network/credentials.

Feeds a couple of fake Appwrite docs through transform_documents() (the
skip-malformed path shared by all three collections) and asserts good docs
convert while a malformed one is skipped, not raised.
"""
from export_import import transform_documents
from transform import mylist_row, history_row


def test_transform_documents_skips_malformed_without_raising():
    good = {
        "userId": "u1", "sourceId": "s1", "itemId": "i1", "title": "T",
        "cover": "c", "url": "u", "type": "anime", "addedAt": 123,
    }
    malformed = {"userId": "u2", "sourceId": "s1"}  # missing itemId/title/... -> KeyError inside mylist_row

    rows, skipped = transform_documents([good, malformed], mylist_row)

    assert skipped == 1
    assert len(rows) == 1
    assert rows[0]["user_key"] == "u1" and rows[0]["item_id"] == "i1"


def test_transform_documents_all_good():
    docs = [
        {"userId": "u1", "sourceId": "s1", "showId": "sh1", "showTitle": "T",
         "position": 1, "duration": 2, "updatedAt": 3, "episodeNumber": 4},
        {"userId": "u2", "sourceId": "s1", "showId": "sh2", "showTitle": "T2",
         "position": 5, "duration": 6, "updatedAt": 7, "episodeNumber": 8},
    ]
    rows, skipped = transform_documents(docs, history_row)
    assert skipped == 0
    assert len(rows) == 2
