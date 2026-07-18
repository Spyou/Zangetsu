from transform import mylist_row, history_row, backup_row

def test_mylist_row_maps_fields():
    doc = {"$id":"abc","userId":"u1","itemId":"i1","sourceId":"s1","title":"T",
           "cover":"c","coverHeaders":'{"Referer":"x"}',"url":"u","type":"anime","addedAt":123}
    r = mylist_row(doc)
    assert r == {"user_key":"u1","source_id":"s1","item_id":"i1","title":"T","cover":"c",
                 "cover_headers":{"Referer":"x"},"url":"u","type":"anime","added_at":123}

def test_history_row_renames_position_duration():
    doc = {"userId":"u1","sourceId":"s1","showId":"sh1","showTitle":"T","position":5000,
           "duration":600000,"updatedAt":999,"episodeNumber":3}
    r = history_row(doc)
    assert r["user_key"]=="u1" and r["position_ms"]==5000 and r["duration_ms"]==600000 and r["episode_number"]==3

def test_backup_row():
    assert backup_row({"userId":"u1","payload":"{}","updatedAt":"2026-07-02T15:07:09.195+00:00"}) \
        == {"user_key":"u1","payload":"{}","updated_at":"2026-07-02T15:07:09.195+00:00"}
