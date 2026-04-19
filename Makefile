EXEC=schedsim
SRC=src/schedsim.s
OBJ=src/schedsim.o
TEST_DIR=test-cases
OUTPUT_DIR=my-outputs

all: $(EXEC)

$(EXEC): $(OBJ)
	ld -o $(EXEC) $(OBJ)

$(OBJ): $(SRC)
	as -o $(OBJ) $(SRC)

testcases: $(EXEC)
	@echo "Running test cases..."
	@mkdir -p $(OUTPUT_DIR)
	@for infile in $(TEST_DIR)/input_*.txt; do \
		base=$$(basename $$infile); \
		outfile=$$(echo $$base | sed 's/input_/output_/'); \
		echo "  > $$infile -> $(OUTPUT_DIR)/$$outfile"; \
		./$(EXEC) < $$infile > $(OUTPUT_DIR)/$$outfile; \
	done

grade: $(EXEC)
	python3 test/grader.py ./$(EXEC) $(TEST_DIR)

clean:
	rm -f $(EXEC) $(OBJ)
	rm -rf $(OUTPUT_DIR)