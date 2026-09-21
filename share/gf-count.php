<?php
/**
 * gf-count.php
 *
 * Counts Gravity Forms entries created within the last N hours.
 * Run via WP-CLI's `eval-file` (never load this directly over HTTP):
 *
 *   wp eval-file gf-count.php <lookback_hours> [comma,separated,form,ids] --path=/var/www/html
 *
 * WP-CLI exposes any extra positional args (after the file path) to this
 * script as $args[0], $args[1], etc.
 *
 * Output (one line per field, easy for bash to parse):
 *   COUNT=<int>
 *   LAST_ENTRY=<date or "never">
 *   FORMS_CHECKED=<comma-separated ids>
 *
 * On failure, prints a single line starting with "ERROR=".
 */

if ( ! class_exists( 'GFAPI' ) ) {
	echo "ERROR=Gravity Forms plugin not found or not active\n";
	return;
}

$lookback_hours = isset( $args[0] ) ? (int) $args[0] : 24;
if ( $lookback_hours <= 0 ) {
	$lookback_hours = 24;
}

$form_id_arg = isset( $args[1] ) ? trim( (string) $args[1] ) : '';

// Resolve which forms to check.
if ( $form_id_arg !== '' ) {
	$form_ids = array_filter( array_map( 'trim', explode( ',', $form_id_arg ) ) );
} else {
	$all_forms = GFAPI::get_forms( true, false ); // active, not trashed
	if ( is_wp_error( $all_forms ) ) {
		echo "ERROR=Could not load forms: " . $all_forms->get_error_message() . "\n";
		return;
	}
	$form_ids = wp_list_pluck( $all_forms, 'id' );
}

if ( empty( $form_ids ) ) {
	echo "ERROR=No active Gravity Forms forms found to check\n";
	return;
}

$start_date = gmdate( 'Y-m-d H:i:s', time() - ( $lookback_hours * HOUR_IN_SECONDS ) );

$total = 0;
foreach ( $form_ids as $form_id ) {
	$search_criteria = array(
		'status'     => 'active',
		'start_date' => $start_date,
	);

	$count = GFAPI::count_entries( $form_id, $search_criteria );

	if ( is_wp_error( $count ) ) {
		// Skip a single bad form rather than failing the whole check,
		// but note it so it shows up in logs.
		error_log( 'gf-count.php: error counting form ' . $form_id . ': ' . $count->get_error_message() );
		continue;
	}

	$total += (int) $count;
}

// For context in the Slack message: when was the most recent submission,
// across all forms, regardless of the lookback window.
$last_entry_date = 'never';
$recent = GFAPI::get_entries(
	$form_ids,
	array( 'status' => 'active' ),
	array( 'key' => 'date_created', 'direction' => 'DESC' ),
	array( 'offset' => 0, 'page_size' => 1 )
);

if ( ! is_wp_error( $recent ) && ! empty( $recent ) ) {
	$last_entry_date = $recent[0]['date_created'];
}

echo "COUNT={$total}\n";
echo "LAST_ENTRY={$last_entry_date}\n";
echo 'FORMS_CHECKED=' . implode( ',', $form_ids ) . "\n";
