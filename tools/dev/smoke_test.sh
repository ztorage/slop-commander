#!/bin/sh
# Load every scene (and the mission-select click-through) and fail on any Godot script error.
cd "$(dirname "$0")/../../godot" || exit 1
status=0
for scene in boot mission_select theatre_viewer model_viewer flight campaign midgame front_end; do
	n=$(godot --path . "res://scenes/$scene.tscn" --quit-after 90 2>&1 | grep -c -E "SCRIPT ERROR|Parse Error")
	echo "$scene: $n errors"; [ "$n" -eq 0 ] || status=1
done
n=$(SC_SELECT_TEST=1 godot --path . res://scenes/mission_select.tscn --quit-after 600 2>&1 | grep -c -E "SCRIPT ERROR|Parse Error")
echo "mission select -> MISN-1A: $n errors"; [ "$n" -eq 0 ] || status=1
n=$(SC_STORY_TEST=4 godot --path . res://scenes/campaign.tscn --quit-after 3000 2>&1 | grep -c -E "SCRIPT ERROR|Parse Error")
echo "campaign click-through: $n errors"; [ "$n" -eq 0 ] || status=1
exit $status
