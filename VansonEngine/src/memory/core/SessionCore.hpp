#pragma once

#include <cstddef>
#include <string>
#include <vector>

struct SessionSnapshot {
  std::string filePath;
  size_t resultCount;
  bool isEmpty;
};

class SessionCore {
public:
  static SessionCore &getInstance();

  SessionCore(const SessionCore &) = delete;
  SessionCore &operator=(const SessionCore &) = delete;

  void pushSnapshot(const std::string &currentFilePath, size_t resultCount);

  bool popSnapshot(std::string &outFilePath, size_t &outCount);

  void clearSnapshots();

  bool hasSnapshots() const;

  size_t getSnapshotCount() const;

private:
  SessionCore() = default;
  ~SessionCore() = default;

  std::vector<SessionSnapshot> _snapshots;

  std::string generateSnapshotPath();
};
