/*
 * Copyright 2016, CZ.NIC z.s.p.o. (http://www.nic.cz/)
 *
 * This file is part of the turris updater.
 *
 * Updater is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 * Updater is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with Updater.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "../lib/events.h"
#include "../lib/interpreter.h"
#include "../lib/util.h"
#include "../lib/arguments.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>

static bool results_interpret(struct interpreter *interpreter, size_t result_count) {
	bool result = true;
	if (result_count >= 2) {
		char *msg;
		ASSERT(interpreter_collect_results(interpreter, "-s", &msg) == -1);
		ERROR("%s", msg);
		err_dump(msg);
	}
	if (result_count >= 1)
		ASSERT(interpreter_collect_results(interpreter, "b", &result) == -1);
	return result;
}

static const enum cmd_op_type cmd_op_allows[] = {
	COT_BATCH, COT_NO_OP, COT_ROOT_DIR, COT_SYSLOG_LEVEL, COT_STDERR_LEVEL, COT_SYSLOG_NAME, COT_LAST
};

static void print_help() {
	fputs("Usage: updater [OPTION]... TOP_LEVEL_CONFIG\n", stderr);
	cmd_args_help(cmd_op_allows);
}

int main(int argc, char *argv[]) {
	// Some setup of the machinery
	state_dump("startup");
	args_backup(argc, (const char **)argv);
	struct events *events = events_new();
	// Parse the arguments
	struct cmd_op *ops = cmd_args_parse(argc, argv, cmd_op_allows);
	struct cmd_op *op = ops;
	// Prepare the interpreter and load it with the embedded lua scripts
	struct interpreter *interpreter = interpreter_create(events);
	const char *error = interpreter_autoload(interpreter);
	if (error) {
		fputs(error, stderr);
		return 1;
	}
	const char *top_level_config = NULL;
	bool batch = false, early_exit = false;
	for (; op->type != COT_EXIT && op->type != COT_CRASH; op ++)
		switch (op->type) {
			case COT_HELP: {
				print_help();
				early_exit = true;
				break;
			}
			case COT_ERR_MSG: {
				fputs(op->parameter, stderr);
				break;
			}
			case COT_NO_OP:
				if (top_level_config) {
					fputs("More than one top level config given. This is not supported\n" ,stderr);
					print_help();
					// What ever is next one, crash.
					(op + 1)->type = COT_CRASH;
					break;
				}
				top_level_config = op->parameter;
				break;
			case COT_BATCH:
				batch = true;
				break;
			case COT_ROOT_DIR: {
				const char *err = interpreter_call(interpreter, "backend.root_dir_set", NULL, "s", op->parameter);
				ASSERT_MSG(!err, "%s", err);
				break;
			}
			case COT_SYSLOG_LEVEL: {
				enum log_level level = log_level_get(op->parameter);
				ASSERT_MSG(level != LL_UNKNOWN, "Unknown log level %s", op->parameter);
				log_syslog_level(level);
				break;
			}
			case COT_SYSLOG_NAME: {
				log_syslog_name(op->parameter);
				break;
			}
			case COT_STDERR_LEVEL: {
				enum log_level level = log_level_get(op->parameter);
				ASSERT_MSG(level != LL_UNKNOWN, "Unknown log level %s", op->parameter);
				log_stderr_level(level);
				break;
			}
			default:
				assert(0);
		}
	if (op->type == COT_EXIT && !early_exit && !top_level_config) {
		fputs("No top level config given, please provide one.\n", stderr);
		print_help();
		op->type = COT_CRASH;
	}
	enum cmd_op_type exit_type = op->type;
	free(ops);

	bool trans_ok = true;
	if (exit_type == COT_EXIT && !early_exit) {
		// Decide what packages need to be downloaded and handled
		const char *err = interpreter_call(interpreter, "updater.prepare", NULL, "s", top_level_config);
		ASSERT_MSG(!err, "%s", err);
		if (!batch) {
			// For now we want to confirm by the user.
			fprintf(stderr, "Press return to continue, CTRL+C to abort\n");
			getchar();
		}
		size_t result_count;
		err = interpreter_call(interpreter, "transaction.perform_queue", &result_count, "");
		ASSERT_MSG(!err, "%s", err);
		trans_ok = results_interpret(interpreter, result_count);
		err = interpreter_call(interpreter, "updater.cleanup", NULL, "b", trans_ok);
		ASSERT_MSG(!err, "%s", err);
	}
	interpreter_destroy(interpreter);
	events_destroy(events);
	arg_backup_clear();
	if (exit_type == COT_EXIT) {
		if (trans_ok) {
			state_dump("done");
			return 0;
		} else {
			state_dump("error");
			return 2;
		}
	} else
		return 1;
}
