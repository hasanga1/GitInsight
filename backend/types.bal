type GitSummery record {|
    string name;
    string username;
    string url;
    int totalFollwers;
    int totalRepos;
    int totalContributions;
    int totalCommits;
    int totalStars;
    int totalPR;
    int totalIssues;
    int totalSizeKB;
    map<string> languages;
|};
